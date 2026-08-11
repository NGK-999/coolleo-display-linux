# Security policy

## Supported versions

Only the newest published alpha is maintained. The project has not reached a
stable security-support commitment.

| Version | Supported |
|---|---|
| `0.1.0-alpha.1` | Yes |
| Older snapshots | No |

## Reporting a vulnerability

Use GitHub private vulnerability reporting if it is enabled for this
repository. If it is unavailable, open a minimal issue asking the maintainer for
a private contact channel, without including exploit details, secrets, device
serials, or personal data.

Include the version, Linux distribution, affected code path, impact, and the
smallest safe reproduction. Do not test against systems or devices you do not
own or have permission to use.

## Security boundaries

The application is intentionally narrow:

- no network client or server;
- no third-party runtime packages;
- dedicated service user and systemd sandbox;
- exact USB bus, VID, PID, and report-descriptor allowlist;
- validation through the same fd used by `HIDIOCSFEATURE`;
- only the known telemetry report ID is sent;
- Intel RAPL access is temporarily widened only to the service group, with the
  exact original UID, GID, and mode stored in a root-only runtime file. Stop
  attempts restoration and logs an error; uninstall refuses to remove managed
  files if explicit restoration fails.

The installer and uninstaller run as root. Review them before execution. Their
default behavior refuses to replace unknown files or remove locally modified
managed files. With `--force`, both scripts preserve durable copies of those
files before replacing or removing them. The uninstaller refuses to stop an
active service if its binary or unit was modified, and the installer applies
the same rule when no trusted manifest matches them. Inspect and stop such a
service manually first. `--purge` irreversibly removes retained installer
backups, including forced-operation backups.

The udev rule grants the service group access to the tested physical interface
topology. The daemon's exact same-fd validation remains required because udev
matching alone is not treated as sufficient authorization for a USB write.
