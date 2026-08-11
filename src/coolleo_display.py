#!/usr/bin/env python3
# Managed by coolleo-display-linux
"""Drive the CPU telemetry display on a tested COOLLEO-compatible cooler."""

from __future__ import annotations

import argparse
import errno
import json
import os
import pathlib
import stat
import struct
import sys
import time
from typing import Callable, Optional, Sequence, Tuple

try:
    import fcntl
except ImportError:  # pragma: no cover - hardware access is Linux-only.
    fcntl = None  # type: ignore[assignment]

try:
    import grp
except ImportError:  # pragma: no cover - account management is Linux-only.
    grp = None  # type: ignore[assignment]


VERSION = "0.1.0-alpha.1"
USB_BUS = 0x03
USB_VENDOR_ID = 0x1A2C
USB_PRODUCT_ID = 0x4D84
REPORT_ID = 0x07
REPORT_LENGTH = 64
MAX_HID_DESCRIPTOR_SIZE = 4096
MAX_HID_READ_SIZE = MAX_HID_DESCRIPTOR_SIZE - 1
SERVICE_GROUP = "coolleo-display"
RAPL_STATE_PATH = pathlib.Path("/run/coolleo-display-rapl.json")
O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)
O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)

# This exact 205-byte descriptor was read from the only validated unit. Keeping
# an allowlist is intentional: VID 1a2c is shared by unrelated input devices.
EXPECTED_DESCRIPTOR = bytes.fromhex(
    "050c0901a101850119002a80031500268003950175108100c0"
    "05010980a1018502198129831500250175019503810295058101c0"
    "0600ff0901a10185031af1002af80015002501750195088102c0"
    "05010906a1018504050719e029e7150025017501950881009530"
    "7501150025010507190029ff8102c0"
    "05010906a101850595387501150025010507193029678102c0"
    "05010906a1018506953875011500250105071968299f8102c0"
    "0601ff0901a10185070903150026ff007508953fb10209041500"
    "26ff007508953f9102c0"
)

_IOC_WRITE = 1
_IOC_READ = 2
HIDIOCGRDESCSIZE = (_IOC_READ << 30) | (4 << 16) | (ord("H") << 8) | 0x01
HIDIOCGRDESC = (
    (_IOC_READ << 30)
    | ((4 + MAX_HID_DESCRIPTOR_SIZE) << 16)
    | (ord("H") << 8)
    | 0x02
)
HIDIOCGRAWINFO = (_IOC_READ << 30) | (8 << 16) | (ord("H") << 8) | 0x03


class DisplayError(RuntimeError):
    """An expected device-discovery, sensor, permission, or HID error."""


class DisplayCountError(DisplayError):
    """The exact number of supported displays was not one."""

    def __init__(self, count: int) -> None:
        self.count = count
        super().__init__(
            "expected exactly one USB 1a2c:4d84 device with the tested HID "
            f"descriptor; found {count}"
        )


class AccessPermissionError(DisplayError):
    """Access changed at runtime and systemd should re-run ExecStartPre."""


def _require_linux_hid() -> None:
    if fcntl is None or sys.platform != "linux":
        raise DisplayError("hidraw access is supported only on Linux")


def _read_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="ascii").strip()


def _write_all(fd: int, payload: bytes) -> None:
    remaining = memoryview(payload)
    while remaining:
        written = os.write(fd, remaining)
        if written <= 0:
            raise OSError(errno.EIO, "short write while saving RAPL state")
        remaining = remaining[written:]


def hid_ioc_set_feature(length: int) -> int:
    """Return HIDIOCSFEATURE(length), as defined by linux/hidraw.h."""

    if not 1 <= length <= MAX_HID_DESCRIPTOR_SIZE:
        raise ValueError("invalid HID feature-report length")
    return (
        ((_IOC_READ | _IOC_WRITE) << 30)
        | (length << 16)
        | (ord("H") << 8)
        | 0x06
    )


def read_hidraw_identity(fd: int) -> Tuple[int, int, int]:
    """Read bus, vendor, and product directly from an open hidraw fd."""

    _require_linux_hid()
    raw_info = bytearray(8)
    fcntl.ioctl(fd, HIDIOCGRAWINFO, raw_info, True)
    return struct.unpack("=Ihh", raw_info)


def read_hidraw_descriptor(fd: int) -> bytes:
    """Read the report descriptor directly from an open hidraw fd."""

    _require_linux_hid()
    raw_size = bytearray(4)
    fcntl.ioctl(fd, HIDIOCGRDESCSIZE, raw_size, True)
    descriptor_size = struct.unpack("=I", raw_size)[0]
    if not 1 <= descriptor_size <= MAX_HID_READ_SIZE:
        raise DisplayError(f"invalid HID descriptor size: {descriptor_size}")

    raw_descriptor = bytearray(4 + MAX_HID_DESCRIPTOR_SIZE)
    struct.pack_into("=I", raw_descriptor, 0, descriptor_size)
    fcntl.ioctl(fd, HIDIOCGRDESC, raw_descriptor, True)
    returned_size = struct.unpack_from("=I", raw_descriptor, 0)[0]
    if returned_size != descriptor_size:
        raise DisplayError(
            "HID descriptor size changed while validating the open device"
        )
    return bytes(raw_descriptor[4 : 4 + returned_size])


def fd_is_supported_display(fd: int) -> bool:
    """Validate identity and descriptor through the same fd used for output."""

    bus, vendor, product = read_hidraw_identity(fd)
    if (bus, vendor, product) != (USB_BUS, USB_VENDOR_ID, USB_PRODUCT_ID):
        return False
    return read_hidraw_descriptor(fd) == EXPECTED_DESCRIPTOR


def open_supported_display(
    dev_root: pathlib.Path = pathlib.Path("/dev"),
) -> Tuple[int, pathlib.Path]:
    """Open exactly one allowlisted display, retaining its validated fd."""

    _require_linux_hid()
    matches: list[Tuple[int, pathlib.Path]] = []
    for node in sorted(dev_root.glob("hidraw*")):
        try:
            fd = os.open(node, os.O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        except OSError:
            continue
        try:
            if fd_is_supported_display(fd):
                matches.append((fd, node))
            else:
                os.close(fd)
        except (DisplayError, OSError):
            os.close(fd)

    if len(matches) == 1:
        return matches[0]
    for fd, _node in matches:
        os.close(fd)
    raise DisplayCountError(len(matches))


def open_all_supported_displays_for_cleanup(
    dev_root: pathlib.Path = pathlib.Path("/dev"),
) -> list[Tuple[int, pathlib.Path]]:
    """Strictly inspect every hidraw node and retain all exact display fds."""

    _require_linux_hid()
    matches: list[Tuple[int, pathlib.Path]] = []
    for node in sorted(dev_root.glob("hidraw*")):
        try:
            fd = os.open(node, os.O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        except OSError as exc:
            for open_fd, _open_node in matches:
                os.close(open_fd)
            raise DisplayError(
                f"could not inspect {node} while restricting hidraw access: {exc}"
            ) from exc
        try:
            if fd_is_supported_display(fd):
                matches.append((fd, node))
            else:
                os.close(fd)
        except (DisplayError, OSError) as exc:
            os.close(fd)
            for open_fd, _open_node in matches:
                os.close(open_fd)
            raise DisplayError(
                f"could not validate {node} while restricting hidraw access: {exc}"
            ) from exc
    return matches


def read_package_temperature(
    hwmon_root: pathlib.Path = pathlib.Path("/sys/class/hwmon"),
) -> float:
    """Read Intel coretemp's Package id 0 sensor in degrees Celsius."""

    for hwmon in sorted(hwmon_root.glob("hwmon*")):
        try:
            if _read_text(hwmon / "name") != "coretemp":
                continue
        except OSError:
            continue
        for label_path in sorted(hwmon.glob("temp*_label")):
            try:
                if _read_text(label_path) != "Package id 0":
                    continue
                input_path = label_path.with_name(
                    label_path.name.replace("_label", "_input")
                )
                return int(_read_text(input_path)) / 1000.0
            except (OSError, ValueError):
                continue
    raise DisplayError("Intel coretemp sensor 'Package id 0' was not found")


def find_rapl_package(
    powercap_root: pathlib.Path = pathlib.Path("/sys/class/powercap"),
) -> pathlib.Path:
    """Find the top-level Intel RAPL zone named package-0."""

    for zone in sorted(powercap_root.glob("intel-rapl:*")):
        try:
            if zone.name.count(":") == 1 and _read_text(zone / "name") == "package-0":
                return zone
        except OSError:
            continue
    raise DisplayError("top-level Intel RAPL zone 'package-0' was not found")


def calculate_package_power(
    start_energy_uj: int,
    end_energy_uj: int,
    max_energy_range_uj: int,
    elapsed_seconds: float,
) -> float:
    """Calculate average package power, including a single RAPL wraparound."""

    if min(start_energy_uj, end_energy_uj) < 0 or max_energy_range_uj <= 0:
        raise DisplayError("invalid Intel RAPL energy values")
    if start_energy_uj > max_energy_range_uj or end_energy_uj > max_energy_range_uj:
        raise DisplayError("Intel RAPL energy value exceeds its declared range")
    if elapsed_seconds <= 0:
        raise DisplayError("invalid elapsed time while measuring package power")
    if end_energy_uj >= start_energy_uj:
        delta_energy_uj = end_energy_uj - start_energy_uj
    else:
        delta_energy_uj = (max_energy_range_uj - start_energy_uj) + end_energy_uj
    return delta_energy_uj / 1_000_000.0 / elapsed_seconds


def measure_package_power(
    zone: pathlib.Path,
    interval: float,
    sleep_fn: Callable[[float], None] = time.sleep,
    monotonic_fn: Callable[[], float] = time.monotonic,
) -> float:
    """Measure mean CPU-package power over an interval."""

    try:
        start_energy = int(_read_text(zone / "energy_uj"))
        max_energy = int(_read_text(zone / "max_energy_range_uj"))
    except PermissionError as exc:
        raise AccessPermissionError(
            f"Intel RAPL access was denied and must be prepared again: {exc}"
        ) from exc
    except (OSError, ValueError) as exc:
        raise DisplayError(f"could not read Intel RAPL: {exc}") from exc

    start_time = monotonic_fn()
    sleep_fn(interval)
    end_time = monotonic_fn()
    try:
        end_energy = int(_read_text(zone / "energy_uj"))
    except PermissionError as exc:
        raise AccessPermissionError(
            f"Intel RAPL access was denied and must be prepared again: {exc}"
        ) from exc
    except (OSError, ValueError) as exc:
        raise DisplayError(f"could not read Intel RAPL again: {exc}") from exc
    return calculate_package_power(
        start_energy, end_energy, max_energy, end_time - start_time
    )


def build_report(temperature_c: float, package_power_w: float) -> bytearray:
    """Build Feature Report 7 using binary digits (not ASCII digits)."""

    temperature = max(0, min(999, int(temperature_c)))
    power = max(0, min(999, int(package_power_w)))
    report = bytearray(REPORT_LENGTH)
    report[0] = REPORT_ID
    report[1:4] = bytes(
        (temperature // 100, (temperature // 10) % 10, temperature % 10)
    )
    report[4] = min(temperature // 10, 10) << 4  # Low nibble 0 means Celsius.
    report[5:8] = bytes((power // 100, (power // 10) % 10, power % 10))
    return report


def send_report(fd: int, report: bytearray) -> None:
    """Send one feature report through an already validated hidraw fd."""

    _require_linux_hid()
    try:
        transferred = fcntl.ioctl(
            fd, hid_ioc_set_feature(len(report)), report, True
        )
    except OSError as exc:
        raise DisplayError(f"failed to send HID feature report: {exc}") from exc
    if transferred != len(report):
        raise DisplayError(
            f"kernel accepted {transferred} report bytes; expected {len(report)}"
        )


def sample_telemetry(interval: float) -> Tuple[float, float, bytearray]:
    zone = find_rapl_package()
    power = measure_package_power(zone, interval)
    temperature = read_package_temperature()
    return temperature, power, build_report(temperature, power)


def update_display_once(interval: float) -> Tuple[float, float, bytearray, pathlib.Path]:
    temperature, power, report = sample_telemetry(interval)
    fd, node = open_supported_display()
    try:
        send_report(fd, report)
    finally:
        os.close(fd)
    return temperature, power, report, node


def _path_is_beneath(path: pathlib.Path, root: pathlib.Path) -> bool:
    try:
        return os.path.commonpath((str(path), str(root))) == str(root)
    except ValueError:
        return False


def _validated_energy_path() -> pathlib.Path:
    energy_path = (find_rapl_package() / "energy_uj").resolve(strict=True)
    allowed_root = pathlib.Path("/sys/devices/virtual/powercap").resolve(strict=True)
    if not _path_is_beneath(energy_path, allowed_root):
        raise DisplayError("refusing to change permissions outside Intel powercap sysfs")
    if energy_path.name != "energy_uj" or not stat.S_ISREG(energy_path.stat().st_mode):
        raise DisplayError("unexpected Intel RAPL energy path")
    return energy_path


def _require_root(operation: str) -> None:
    if not hasattr(os, "geteuid") or os.geteuid() != 0:
        raise DisplayError(f"{operation} must run as root")


def _load_access_state() -> dict:
    try:
        state_stat = RAPL_STATE_PATH.lstat()
    except FileNotFoundError:
        raise DisplayError("saved Intel RAPL permission state was not found")
    if not stat.S_ISREG(state_stat.st_mode) or state_stat.st_uid != 0:
        raise DisplayError("saved Intel RAPL permission state is not a root-owned file")
    if stat.S_IMODE(state_stat.st_mode) & 0o077:
        raise DisplayError("saved Intel RAPL permission state is accessible by non-root users")
    try:
        state = json.loads(RAPL_STATE_PATH.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise DisplayError(f"could not read saved Intel RAPL permissions: {exc}") from exc
    required = {"version", "path", "uid", "gid", "mode"}
    if not isinstance(state, dict) or set(state) != required or state["version"] != 1:
        raise DisplayError("saved Intel RAPL permission state has an invalid format")
    if not isinstance(state["path"], str) or not all(
        type(state[key]) is int for key in ("uid", "gid", "mode")
    ):
        raise DisplayError("saved Intel RAPL ownership or mode is invalid")
    return state


def restore_rapl_access(missing_ok: bool = False) -> None:
    """Restore the exact Intel RAPL ownership and mode saved at service start."""

    _require_root("--restore-access")
    if missing_ok and not RAPL_STATE_PATH.exists():
        return
    state = _load_access_state()
    current_path = _validated_energy_path()
    saved_path = pathlib.Path(state["path"])
    if saved_path != current_path:
        raise DisplayError("saved Intel RAPL path does not match the current package zone")
    mode = state["mode"]
    if not 0 <= mode <= 0o7777 or min(state["uid"], state["gid"]) < 0:
        raise DisplayError("saved Intel RAPL ownership or mode is out of range")
    try:
        os.chown(current_path, state["uid"], state["gid"])
        os.chmod(current_path, mode)
        RAPL_STATE_PATH.unlink()
    except OSError as exc:
        raise DisplayError(f"could not restore Intel RAPL permissions: {exc}") from exc


def prepare_rapl_access() -> None:
    """Grant group read access while preserving reversible permission state."""

    _require_root("--prepare-access")
    restore_rapl_access(missing_ok=True)
    if grp is None:
        raise DisplayError("group lookup is supported only on Linux")
    try:
        service_gid = grp.getgrnam(SERVICE_GROUP).gr_gid
    except KeyError as exc:
        raise DisplayError(f"required group '{SERVICE_GROUP}' does not exist") from exc

    energy_path = _validated_energy_path()
    original = energy_path.stat()
    state = {
        "version": 1,
        "path": str(energy_path),
        "uid": original.st_uid,
        "gid": original.st_gid,
        "mode": stat.S_IMODE(original.st_mode),
    }
    temporary = RAPL_STATE_PATH.with_name(
        f".{RAPL_STATE_PATH.name}.{os.getpid()}.tmp"
    )
    fd: Optional[int] = None
    try:
        fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600,
        )
        payload = (json.dumps(state, sort_keys=True) + "\n").encode("utf-8")
        _write_all(fd, payload)
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(temporary, RAPL_STATE_PATH)
        os.chown(energy_path, original.st_uid, service_gid)
        os.chmod(energy_path, state["mode"] | stat.S_IRGRP)
    except OSError as exc:
        if fd is not None:
            os.close(fd)
        try:
            temporary.unlink(missing_ok=True)
            os.chown(energy_path, original.st_uid, original.st_gid)
            os.chmod(energy_path, state["mode"])
            RAPL_STATE_PATH.unlink(missing_ok=True)
        except OSError:
            pass
        raise DisplayError(f"could not grant reversible Intel RAPL access: {exc}") from exc


def lock_current_hidraw_access() -> None:
    """Remove group access from a connected display before deleting the group."""

    _require_root("--lock-hidraw-access")
    matches = open_all_supported_displays_for_cleanup()
    try:
        for fd, _node in matches:
            os.fchown(fd, 0, 0)
            os.fchmod(fd, 0o600)
    except OSError as exc:
        raise DisplayError(f"could not restrict the current hidraw node: {exc}") from exc
    finally:
        for fd, _node in matches:
            os.close(fd)


def print_sample(
    temperature: float,
    power: float,
    report: bytearray,
    node: Optional[pathlib.Path] = None,
) -> None:
    fields = []
    if node is not None:
        fields.append(f"device={node}")
    display_temperature = report[1] * 100 + report[2] * 10 + report[3]
    display_power = report[5] * 100 + report[6] * 10 + report[7]
    fields.extend(
        (
            f"temperature={temperature:.1f} C",
            f"package_power={power:.2f} W",
            f"display_temperature={display_temperature} C",
            f"display_power={display_power} W",
            f"report={bytes(report[:8]).hex(' ')}",
        )
    )
    print(" ".join(fields), flush=True)


def check_environment(interval: float) -> None:
    fd, node = open_supported_display()
    os.close(fd)
    temperature, power, report = sample_telemetry(interval)
    print_sample(temperature, power, report, node)
    print("check=ok hid_write=not_performed", flush=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    parser.add_argument(
        "--interval",
        type=float,
        default=2.0,
        help="seconds used for each telemetry sample (default: 2)",
    )
    parser.add_argument(
        "--retry-interval",
        type=float,
        default=10.0,
        help="seconds before retrying an expected hardware error (default: 10)",
    )
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--once", action="store_true", help="measure and write once")
    modes.add_argument(
        "--dry-run", action="store_true", help="measure once without writing USB"
    )
    modes.add_argument(
        "--check",
        action="store_true",
        help="validate device and sensors without writing USB",
    )
    modes.add_argument("--prepare-access", action="store_true", help=argparse.SUPPRESS)
    modes.add_argument("--restore-access", action="store_true", help=argparse.SUPPRESS)
    modes.add_argument(
        "--lock-hidraw-access", action="store_true", help=argparse.SUPPRESS
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not 0.25 <= args.interval <= 60.0:
        parser.error("--interval must be between 0.25 and 60 seconds")
    if not 5.0 <= args.retry_interval <= 300.0:
        parser.error("--retry-interval must be between 5 and 300 seconds")

    try:
        if args.prepare_access:
            prepare_rapl_access()
            return 0
        if args.restore_access:
            restore_rapl_access(missing_ok=True)
            return 0
        if args.lock_hidraw_access:
            lock_current_hidraw_access()
            return 0
        if args.check:
            check_environment(args.interval)
            return 0
        if args.dry_run:
            temperature, power, report = sample_telemetry(args.interval)
            print_sample(temperature, power, report)
            return 0
        if args.once:
            temperature, power, report, node = update_display_once(args.interval)
            print_sample(temperature, power, report, node)
            return 0

        last_error: Optional[str] = None
        announced_success = False
        while True:
            try:
                temperature, power, report, node = update_display_once(args.interval)
                if last_error is not None:
                    print("coolleo-display: hardware access recovered", flush=True)
                if not announced_success:
                    print_sample(temperature, power, report, node)
                    announced_success = True
                last_error = None
            except AccessPermissionError:
                raise
            except DisplayError as exc:
                message = str(exc)
                if message != last_error:
                    print(f"coolleo-display: {message}; retrying", flush=True)
                    last_error = message
                time.sleep(args.retry_interval)
    except DisplayError as exc:
        print(f"coolleo-display: {exc}", file=sys.stderr, flush=True)
        return 1
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
