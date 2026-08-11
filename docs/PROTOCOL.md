# Protocol notes

This document records the evidence behind the narrow protocol implemented by
`coolleo-display-linux`. It is not a generic COOLLEO protocol specification.

## Tested USB interface

- Bus: USB HID (`BUS_USB`, Linux value `0x03`)
- Vendor ID: `0x1a2c`
- Product ID: `0x4d84`
- Physical HID interface used by the tested unit: interface 01
- Expected report-descriptor length: 205 bytes
- Vendor collection: Usage Page `0xff01`, Usage `0x0001`
- Telemetry Feature Report ID: `0x07`

Interface 01 also contains auxiliary consumer, system-control, and keyboard
reports. It must not be described as a purely vendor-defined interface. The
daemon allows the entire exact descriptor and then emits only Feature Report
`0x07`.

The VID is commonly used by keyboard-like peripherals. For that reason, the
application performs `HIDIOCGRAWINFO`, `HIDIOCGRDESCSIZE`, and `HIDIOCGRDESC`
on the same open file descriptor later passed to `HIDIOCSFEATURE`. A sysfs name
or VID/PID match alone is not accepted.

## Linux feature-report size

The descriptor declares Report ID `0x07` followed by 63 feature bytes. Linux
`hidraw` therefore receives a 64-byte buffer whose first byte is the report ID.
The tested Windows call used a 65-byte application buffer because its code
copied a 64-byte frame and retained a trailing zero. These API-level buffer
sizes should not be copied between platforms without understanding where the
report ID is carried.

## Implemented frame

All digit fields contain binary values `0x00` through `0x09`, not ASCII.

| Byte | Meaning |
|---:|---|
| 0 | Report ID `0x07` |
| 1 | Temperature hundreds digit |
| 2 | Temperature tens digit |
| 3 | Temperature units digit |
| 4 high nibble | `min(trunc(temp_c / 10), 10)` level |
| 4 low nibble | Unit: `0` Celsius; `1` Fahrenheit (not emitted by this project) |
| 5 | CPU package-power hundreds digit |
| 6 | CPU package-power tens digit |
| 7 | CPU package-power units digit |
| 8–63 | Zero |

Example for 50 °C and 34 W:

```text
07 00 05 00 50 00 03 04 00 00 ... 00
```

Values are truncated to whole numbers and clamped to the displayable range
0–999. Byte 4's level remains based on Celsius.

## Sensor mapping

The proprietary Windows application was statically observed mapping the
temperature field to CPU Package / CPU (Tctl/Tdie), and the power field to CPU
Package Power. This implementation intentionally supports only the Linux Intel
equivalents:

- `coretemp` label `Package id 0`;
- top-level Intel RAPL zone named `package-0`.

It does not claim AMD support. A future AMD backend needs separate hardware
evidence and tests; silently substituting a different sensor is not acceptable.

## Evidence and validation status

- Static control-flow and constant analysis linked PID `4d84` to this frame
  layout in the vendor application.
- The physical device's full 205-byte report descriptor was read on Linux.
- A Linux `HIDIOCSFEATURE(64)` call returned 64 and the corresponding USB
  control transfer was observed on one unit.
- Temperature and Intel RAPL inputs were measured on Ubuntu Server 24.04.
- Independent visual confirmation that both displayed numbers follow those
  Linux inputs is still pending.

Classification: **partially validated / alpha**. Transport and framing have
direct evidence; end-to-end visual agreement is the remaining acceptance test.

## Explicitly excluded operations

This project does not implement:

- the separate `07 fd ...` version/status query;
- input-report requests;
- protocol branches seen for PIDs `4c84` or `4e87`;
- firmware download or update;
- fan, pump, RGB, or motherboard control.

Do not experiment with guessed commands in a pull request. New writes require a
capture or equivalent primary evidence, a device-specific allowlist, review,
and an explained recovery boundary.

No proprietary executable, DLL, SDK, or firmware is included in this
repository. The implementation is an independently written interoperability
client based on behavior observed on hardware and static protocol analysis.
