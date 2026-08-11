# coolleo-display-linux

Experimental, unofficial Linux support for the CPU telemetry display found on
one tested **MACH1 BOREAL B40S-DIG-BK-V2** unit. Its USB behavior matches the
`1a2c:4d84` protocol branch found in software published for the COOLLEO B40S
DIG V2. It displays Intel CPU package temperature and package power without
running the proprietary Windows application.

> **Alpha software:** USB feature-report transport has been reproduced and
> observed on one physical unit, but the final displayed numbers still need an
> independent visual confirmation. Read the compatibility table before
> installing. This project is not affiliated with or endorsed by COOLLEO,
> MACH1, SEMICO, or their suppliers. Product names are used only to identify
> tested hardware.

[Leia em português do Brasil](README.pt-BR.md)

## What it does

Every two seconds, the daemon:

1. reads `Package id 0` from Linux `coretemp`;
2. calculates mean package power from Intel RAPL;
3. builds the tested 64-byte HID Feature Report `0x07`;
4. opens a `hidraw` device and validates its USB identity and exact 205-byte
   report descriptor through that same open file descriptor;
5. sends temperature and power, then closes the device.

It has no network code and does **not** control fan speed, pump speed, RGB,
firmware, or motherboard settings. It does not contain or redistribute the
vendor's Windows executable, drivers, SDK, or DLLs.

## Compatibility

| Component | Status |
|---|---|
| USB `1a2c:4d84` with the exact descriptor in `src/coolleo_display.py` | Experimental; transport validated on one unit |
| Ubuntu Server 24.04, Linux 6.8, Intel Core i9-11900KF | Hardware-tested environment |
| Other Intel CPUs exposing `coretemp` and top-level RAPL `package-0` | Expected to work, not yet hardware-tested |
| AMD CPUs | Not supported |
| USB PIDs `1a2c:4c84` and `1a2c:4e87` | Not supported; they use different protocol branches |
| USB `048d:5702` | Not this display; not supported |
| Visual agreement with Linux sensor values | Pending independent confirmation |

The exact-descriptor allowlist is intentional. Vendor ID `1a2c` is shared by
unrelated keyboard-like devices, so VID/PID alone is not a safe write target.

## Requirements

- Linux with systemd, udev, and `hidraw`;
- Python 3.9 or newer (standard library only);
- an Intel CPU exposing `coretemp` and Intel RAPL `package-0`;
- the tested USB device connected internally;
- root access for installation.

## Install

Clone the repository, enter its directory, review the scripts, and install:

```bash
git clone https://github.com/NGK-999/coolleo-display-linux.git
cd coolleo-display-linux
sudo ./scripts/install.sh
```

The installer performs a read-only hardware check before enabling the service.
If the cooler is intentionally disconnected, installation can continue with:

```bash
sudo ./scripts/install.sh --allow-missing-display
```

In that mode the service stays active, logs one concise error, and retries when
the hardware becomes available. Do not use `--force` unless you have inspected
the destination file named in the error; it explicitly authorizes a backed-up
replacement of an unknown or locally modified file.

## Verify and use

Read-only validation (does not send a USB report):

```bash
sudo /usr/local/bin/coolleo-display --check --interval 1
```

Service and recent logs:

```bash
sudo systemctl status coolleo-display.service --no-pager
sudo journalctl -u coolleo-display.service -n 30 --no-pager
```

One controlled telemetry write:

```bash
sudo systemctl stop coolleo-display.service
sudo /usr/local/bin/coolleo-display --once --interval 1
sudo systemctl start coolleo-display.service
```

Compare `display_temperature` and `display_power` from the `--once` command
with the physical display. The decimal sensor values are sampled inputs and are
intentionally truncated for the three-digit report. See
[`docs/SUPPORT.md`](docs/SUPPORT.md) before reporting a mismatch.

## Uninstall and rollback

From the same repository checkout:

```bash
sudo ./scripts/uninstall.sh
```

The uninstaller verifies installed-file hashes, stops the daemon, requires a
successful restoration of the saved Intel RAPL ownership/mode, restricts the
current display node, and restores files that existed before installation.
Backups remain under
`/var/lib/coolleo-display/backups`.

To intentionally remove those retained backups too:

```bash
sudo ./scripts/uninstall.sh --purge
```

`--purge` is irreversible. `--force` permits removal of files changed after
installation, so inspect them first. You may run `--purge` later, from the same
checkout, after a normal uninstall has already removed the application.

## Security design

- no network access and no third-party Python packages;
- dedicated unprivileged system user;
- a narrowly matched udev rule plus exact validation on the same open fd;
- only the known 64-byte telemetry report is emitted;
- reversible, exact preservation of Intel RAPL file ownership and mode;
- restrictive systemd sandboxing;
- installers refuse unknown or modified files by default.

Read [`SECURITY.md`](SECURITY.md) and [`docs/PROTOCOL.md`](docs/PROTOCOL.md) for
the threat model and protocol evidence.

## Contributing

Bug reports and tested hardware evidence are welcome. Do not submit vendor
binaries, guessed commands, firmware operations, or support claims without
reproducible evidence. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md).

Created by Igor with AI-assisted development, protocol review, automated tests,
and validation on the original laboratory unit. The validation status above is
the source of truth; AI assistance is not treated as proof of correctness.

Licensed under the [MIT License](LICENSE).
