## Which file

| System | File |
|---|---|
| macOS (Apple Silicon only) | `NIST-Viewer_<version>_aarch64.dmg` |
| Windows | `NIST-Viewer_<version>_x64-setup.exe`, or the `.msi` for managed installs |
| Linux, Debian or Ubuntu | `NIST-Viewer_<version>_amd64.deb` (x86_64) or `_arm64.deb` |
| Linux, other | `NIST-Viewer_<version>_amd64.AppImage` (x86_64) or `_aarch64.AppImage` |

## Check the download

Before moving the files into another network, check them against
`SHA256SUMS`:

- macOS and Linux: `shasum -a 256 -c SHA256SUMS --ignore-missing`
- Windows (PowerShell): `Get-FileHash <file>`, and compare with the line in
  `SHA256SUMS`

## Install

The builds are not signed with a certificate, so the system asks once.

- **macOS:** open the `.dmg` and drag NIST Viewer to Applications. If macOS
  says it cannot check the app, open System Settings → Privacy & Security
  and choose Open Anyway; or run
  `xattr -dr com.apple.quarantine "/Applications/NIST Viewer.app"`.
- **Windows:** run the installer. It shows an unknown publisher; on a
  machine with internet access, SmartScreen first needs More info → Run
  anyway.
- **Linux:** `sudo apt install ./NIST-Viewer_<version>_amd64.deb`, or make
  the AppImage executable (`chmod +x`) and run it. Needs OpenSSL 3 and
  WebKitGTK 4.1, as on Ubuntu 22.04, Debian 12, Fedora 36 or later.

Machines that only allow signed or notarized software cannot run these
builds.
