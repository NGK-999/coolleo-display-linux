# Changelog

All notable changes to this project will be documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0-alpha.1] - 2026-08-11

### Added

- Experimental Linux daemon for the tested USB `1a2c:4d84` HID descriptor.
- Intel `coretemp` package-temperature and Intel RAPL package-power backends.
- Exact same-file-descriptor USB identity and descriptor validation.
- Reversible systemd/udev installer and hash-aware uninstaller.
- Hardware-free unit tests and a GitHub Actions validation workflow.
- English and Brazilian Portuguese documentation.

### Safety limits

- Only Feature Report `0x07` telemetry writes are implemented.
- No fan, pump, RGB, firmware, or firmware-query commands are implemented.
- AMD sensors and USB PIDs `4c84` and `4e87` are not supported.
- USB transport is validated on one unit; final visual confirmation remains
  pending before this software can be considered stable.
