# Contributing

Thank you for helping improve this experimental interoperability project.

## Before opening a change

1. Read `README.md`, `SECURITY.md`, and `docs/PROTOCOL.md`.
2. Confirm the request is about the display, not motherboard RGB device
   `048d:5702`, fan control, or general power tuning.
3. Open an issue before adding a new USB PID, sensor backend, or report type.
4. Never commit vendor executables, DLLs, SDKs, firmware, captures containing
   serial numbers, credentials, private IPs, or other personal information.

## Local checks

Python 3.9 or newer is required. No package installation is needed.

```bash
python3 -m py_compile src/coolleo_display.py tests/test_coolleo_display.py
python3 -m unittest discover -s tests -v
bash -n scripts/install.sh scripts/uninstall.sh
shellcheck scripts/install.sh scripts/uninstall.sh
```

On a recent systemd/udev Linux host, also run:

```bash
sudo groupadd --system coolleo-display  # only if the group does not exist
sudo install -m 0755 src/coolleo_display.py /usr/local/bin/coolleo-display
systemd-analyze verify packaging/coolleo-display.service
udevadm verify packaging/70-coolleo-display.rules
```

Do not perform a USB write merely to make a test pass. Hardware tests require an
owned device, a documented expected frame, and explicit confirmation of the
physical result.

## Pull requests

Keep changes small and explain:

- the problem and evidence;
- files changed and why;
- normal and error cases tested;
- whether a real device was used;
- how to revert the change;
- what remains unvalidated.

Tests must not weaken the descriptor allowlist or replace hardware evidence with
mocked success. English is the source documentation language; update
`README.pt-BR.md` when user-facing behavior changes.
