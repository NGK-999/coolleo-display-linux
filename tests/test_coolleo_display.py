"""Hardware-free unit tests for coolleo-display-linux."""

from __future__ import annotations

import contextlib
import io
import pathlib
import struct
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "src"))

import coolleo_display as app  # noqa: E402


class ReportTests(unittest.TestCase):
    def test_known_celsius_and_power_vector(self) -> None:
        report = app.build_report(50.9, 34.8)
        self.assertEqual(len(report), 64)
        self.assertEqual(report[:8], bytes.fromhex("07 00 05 00 50 00 03 04"))
        self.assertEqual(report[8:], bytes(56))

    def test_values_are_truncated_and_clamped(self) -> None:
        self.assertEqual(
            app.build_report(-10.0, 1234.0)[:8],
            bytes.fromhex("07 00 00 00 00 09 09 09"),
        )

    def test_descriptor_and_ioctl_constants_match_linux_abi(self) -> None:
        self.assertEqual(len(app.EXPECTED_DESCRIPTOR), 205)
        self.assertEqual(app.HIDIOCGRDESCSIZE, 0x80044801)
        self.assertEqual(app.HIDIOCGRDESC, 0x90044802)
        self.assertEqual(app.HIDIOCGRAWINFO, 0x80084803)
        self.assertEqual(app.hid_ioc_set_feature(64), 0xC0404806)

    def test_invalid_feature_report_lengths_are_rejected(self) -> None:
        for length in (0, 4097):
            with self.subTest(length=length), self.assertRaises(ValueError):
                app.hid_ioc_set_feature(length)


class PowerTests(unittest.TestCase):
    def test_power_without_wraparound(self) -> None:
        self.assertAlmostEqual(
            app.calculate_package_power(10_000_000, 30_000_000, 100_000_000, 2.0),
            10.0,
        )

    def test_power_with_single_wraparound(self) -> None:
        self.assertAlmostEqual(
            app.calculate_package_power(90_000_000, 10_000_000, 100_000_000, 2.0),
            10.0,
        )

    def test_invalid_power_inputs_are_rejected(self) -> None:
        cases = (
            (-1, 1, 100, 1.0),
            (1, 1, 0, 1.0),
            (101, 1, 100, 1.0),
            (1, 1, 100, 0.0),
        )
        for values in cases:
            with self.subTest(values=values), self.assertRaises(app.DisplayError):
                app.calculate_package_power(*values)

    def test_measurement_reads_before_and_after_sleep(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            zone = pathlib.Path(directory)
            (zone / "energy_uj").write_text("10000000\n", encoding="ascii")
            (zone / "max_energy_range_uj").write_text(
                "100000000\n", encoding="ascii"
            )

            def fake_sleep(_seconds: float) -> None:
                (zone / "energy_uj").write_text("30000000\n", encoding="ascii")

            clock = iter((10.0, 12.0))
            result = app.measure_package_power(
                zone, 2.0, sleep_fn=fake_sleep, monotonic_fn=lambda: next(clock)
            )
            self.assertAlmostEqual(result, 10.0)


class SensorDiscoveryTests(unittest.TestCase):
    def test_coretemp_package_sensor_is_selected_by_label(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            other = root / "hwmon0"
            other.mkdir()
            (other / "name").write_text("acpitz\n", encoding="ascii")
            coretemp = root / "hwmon1"
            coretemp.mkdir()
            (coretemp / "name").write_text("coretemp\n", encoding="ascii")
            (coretemp / "temp1_label").write_text("Core 0\n", encoding="ascii")
            (coretemp / "temp1_input").write_text("41000\n", encoding="ascii")
            (coretemp / "temp2_label").write_text(
                "Package id 0\n", encoding="ascii"
            )
            (coretemp / "temp2_input").write_text("52750\n", encoding="ascii")
            self.assertEqual(app.read_package_temperature(root), 52.75)

    def test_missing_coretemp_is_an_expected_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(app.DisplayError):
                app.read_package_temperature(pathlib.Path(directory))

    @unittest.skipIf(sys.platform == "win32", "Windows forbids ':' in filenames")
    def test_top_level_rapl_package_is_selected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            nested = root / "intel-rapl:0:0"
            nested.mkdir()
            (nested / "name").write_text("package-0\n", encoding="ascii")
            package = root / "intel-rapl:1"
            package.mkdir()
            (package / "name").write_text("package-0\n", encoding="ascii")
            self.assertEqual(app.find_rapl_package(root), package)


class FakeFcntl:
    def __init__(self, descriptor: bytes, returned_size: int | None = None) -> None:
        self.descriptor = descriptor
        self.returned_size = returned_size

    def ioctl(self, _fd: int, request: int, buffer: bytearray, _mutate: bool) -> int:
        if request == app.HIDIOCGRAWINFO:
            buffer[:] = struct.pack("=IHH", 3, 0x1A2C, 0x4D84)
        elif request == app.HIDIOCGRDESCSIZE:
            buffer[:] = struct.pack("=I", len(self.descriptor))
        elif request == app.HIDIOCGRDESC:
            requested_size = struct.unpack_from("=I", buffer, 0)[0]
            if requested_size != len(self.descriptor):
                raise AssertionError(
                    f"descriptor ioctl requested {requested_size}; "
                    f"expected {len(self.descriptor)}"
                )
            size = len(self.descriptor) if self.returned_size is None else self.returned_size
            struct.pack_into("=I", buffer, 0, size)
            buffer[4 : 4 + len(self.descriptor)] = self.descriptor
        else:
            raise AssertionError(f"unexpected ioctl: {request:#x}")
        return 0


class HidValidationTests(unittest.TestCase):
    def test_identity_and_exact_descriptor_are_read_from_fd(self) -> None:
        fake = FakeFcntl(app.EXPECTED_DESCRIPTOR)
        with mock.patch.object(app, "fcntl", fake), mock.patch.object(
            app.sys, "platform", "linux"
        ):
            self.assertEqual(app.read_hidraw_identity(42), (3, 0x1A2C, 0x4D84))
            self.assertEqual(
                app.read_hidraw_descriptor(42), app.EXPECTED_DESCRIPTOR
            )
            self.assertTrue(app.fd_is_supported_display(42))

    def test_descriptor_size_change_is_rejected(self) -> None:
        fake = FakeFcntl(app.EXPECTED_DESCRIPTOR, returned_size=204)
        with mock.patch.object(app, "fcntl", fake), mock.patch.object(
            app.sys, "platform", "linux"
        ), self.assertRaises(app.DisplayError):
            app.read_hidraw_descriptor(42)

    def test_environment_check_never_sends_a_report(self) -> None:
        output = io.StringIO()
        with mock.patch.object(app, "open_supported_display", return_value=(42, pathlib.Path("/dev/hidraw7"))), mock.patch.object(
            app, "sample_telemetry", return_value=(50.0, 34.0, app.build_report(50, 34))
        ), mock.patch.object(app.os, "close") as close_mock, mock.patch.object(
            app, "send_report"
        ) as send_mock, contextlib.redirect_stdout(output):
            app.check_environment(0.25)
        close_mock.assert_called_once_with(42)
        send_mock.assert_not_called()
        self.assertIn("check=ok hid_write=not_performed", output.getvalue())
        self.assertIn("display_temperature=50 C", output.getvalue())
        self.assertIn("display_power=34 W", output.getvalue())

    def test_send_report_requires_full_kernel_transfer(self) -> None:
        report = app.build_report(50, 34)
        fake = mock.Mock()
        fake.ioctl.return_value = 64
        with mock.patch.object(app, "fcntl", fake), mock.patch.object(
            app.sys, "platform", "linux"
        ):
            app.send_report(42, report)
        fake.ioctl.assert_called_once_with(42, 0xC0404806, report, True)

        fake.ioctl.return_value = 63
        with mock.patch.object(app, "fcntl", fake), mock.patch.object(
            app.sys, "platform", "linux"
        ), self.assertRaises(app.DisplayError):
            app.send_report(42, report)


class StateSafetyTests(unittest.TestCase):
    class FakeStatePath:
        def __init__(self, payload: str) -> None:
            self.payload = payload

        def lstat(self) -> types.SimpleNamespace:
            return types.SimpleNamespace(st_mode=0o100600, st_uid=0)

        def read_text(self, encoding: str) -> str:
            self.test_encoding = encoding
            return self.payload

    def test_non_object_or_non_string_state_is_rejected(self) -> None:
        invalid_payloads = (
            "[]",
            '{"version":1,"path":1,"uid":0,"gid":0,"mode":256}',
            '{"version":1,"path":"/sys/x","uid":true,"gid":0,"mode":256}',
        )
        for payload in invalid_payloads:
            with self.subTest(payload=payload), mock.patch.object(
                app, "RAPL_STATE_PATH", self.FakeStatePath(payload)
            ), self.assertRaises(app.DisplayError):
                app._load_access_state()

    def test_write_all_retries_short_writes(self) -> None:
        calls: list[bytes] = []

        def short_write(_fd: int, data: memoryview) -> int:
            calls.append(bytes(data))
            return min(2, len(data))

        with mock.patch.object(app.os, "write", side_effect=short_write):
            app._write_all(5, b"abcdef")
        self.assertEqual(calls, [b"abcdef", b"cdef", b"ef"])

    def test_zero_length_write_is_rejected(self) -> None:
        with mock.patch.object(app.os, "write", return_value=0), self.assertRaises(
            OSError
        ):
            app._write_all(5, b"x")


class PathSafetyTests(unittest.TestCase):
    def test_path_must_be_beneath_exact_root(self) -> None:
        self.assertTrue(
            app._path_is_beneath(
                pathlib.Path("/sys/devices/virtual/powercap/a"),
                pathlib.Path("/sys/devices/virtual/powercap"),
            )
        )
        self.assertFalse(
            app._path_is_beneath(
                pathlib.Path("/sys/devices/virtual/powercap-evil/a"),
                pathlib.Path("/sys/devices/virtual/powercap"),
            )
        )


if __name__ == "__main__":
    unittest.main()
