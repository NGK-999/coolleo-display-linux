# Support and hardware confirmation

Please read the compatibility table in the main README first. This alpha only
supports Intel Linux telemetry and one exact `1a2c:4d84` descriptor.

## Safe diagnostic bundle

The following commands do not write a telemetry report:

```bash
sudo /usr/local/bin/coolleo-display --check --interval 1
sudo systemctl status coolleo-display.service --no-pager
sudo journalctl -u coolleo-display.service -n 50 --no-pager
python3 --version
uname -srmo
```

Before posting output, remove hostnames, usernames, IP addresses, serial
numbers, mount paths, and anything else that identifies your network or files.
Never post passwords, access tokens, SSH keys, or an entire system journal.

## Missing install manifest

If `/var/lib/coolleo-display/install-manifest` is missing while managed files
still exist **and there is no valid**
`/var/lib/coolleo-display/uninstalled-state` marker, do **not** reinstall over
them and do not recreate the manifest by hand. The marker is written only after
a successful uninstall; without either record, the scripts cannot distinguish
an interrupted installation from pre-existing local files. Guessing could
overwrite or delete unrelated configuration.

Preserve the current state and open an issue. Include the output of the
following read-only commands after removing any information you consider
private:

```bash
sudo ls -la /var/lib/coolleo-display /var/lib/coolleo-display/backups
sudo sha256sum /usr/local/bin/coolleo-display \
  /etc/systemd/system/coolleo-display.service \
  /etc/udev/rules.d/70-coolleo-display.rules
sudo systemctl status coolleo-display.service --no-pager
```

Automatic removal intentionally stops in this state because it cannot know
whether it should delete each file or restore a pre-installation backup.

## Visual acceptance test

This is the missing end-to-end validation for the original unit:

1. Run the read-only check to confirm the device and sensors are available.
2. Stop the background service so only one process can send reports.
3. Run one controlled report and retain that command's output.
4. Compare its `display_temperature` and `display_power` whole numbers with the
   physical display within a few seconds.
5. Start the service again even if the comparison fails.

```bash
sudo /usr/local/bin/coolleo-display --check --interval 1
sudo systemctl stop coolleo-display.service
sudo /usr/local/bin/coolleo-display --once --interval 1
sudo systemctl start coolleo-display.service
```

Record:

- cooler label/model exactly as printed;
- USB VID/PID;
- Linux distribution and kernel;
- CPU model;
- the `--once` output;
- the two numbers physically shown;
- whether the service returned to `active`.

A difference of one unit can result from truncation or sampling time. A blank
display, swapped values, impossible digits, or a persistent larger difference
is a failure: stop the service and report it without attempting other commands.

## Issue checklist

Use the repository's bug-report form. A useful report contains:

- exact reproduction steps;
- expected and observed behavior;
- redacted output from the safe diagnostic bundle;
- whether `--check` passed;
- whether any file under `/usr/local/bin`, `/etc/systemd/system`, or
  `/etc/udev/rules.d` was edited after installation;
- whether the hardware matches the exact compatibility row.

Do not attach vendor binaries or firmware. Link to the vendor's official
download page if it is relevant.

## Message template for the cooler vendor

The following can be adapted when asking the manufacturer for documentation or
permission to reference a model. It deliberately does not claim official
support or a finished driver.

```text
Subject: Unofficial experimental Linux telemetry support for B40S DIG V2

Hello,

I own a MACH1 BOREAL B40S-DIG-BK-V2 unit whose USB behavior matches the
1a2c:4d84 protocol branch in software published for the COOLLEO B40S DIG V2. I
created an independent, open-source, experimental Linux client for its CPU
telemetry display. The code sends only temperature and CPU package-power
telemetry. It does not include your binaries, SDK, or firmware; product names
are used only to identify tested hardware. It does not control fans, RGB, or
firmware.

The project is clearly marked unofficial and alpha because end-to-end visual
confirmation on the original test unit is still pending. Would you be willing
to confirm the telemetry report format, provide public protocol documentation,
or test the implementation on additional hardware revisions? I would also
appreciate your preferred wording for model compatibility and trademark
attribution.

Repository: https://github.com/NGK-999/coolleo-display-linux

Thank you,
Igor
```
