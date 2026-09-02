# Grok Bot Linux Repack

Unofficial distro packaging for [Grok Bot](https://cursor.com/grok) on Linux. xAI publishes official Linux builds (x64 and arm64) as `.deb` only — this repo repacks them for the package managers upstream doesn't serve: Arch (AUR) and Fedora (COPR), plus a portable tarball for everything else.

The payload is repacked **verbatim** from the official `.deb` — same Electron runtime, same native modules, zero patching.

Found a bug? Please open an issue. I'd really appreciate it!

## Install

**Arch (AUR):**

```bash
yay -S grokbot-linux-port-bin
```

**Fedora (COPR):**

```bash
sudo dnf copr enable nichokas/grokbot-linux-port
sudo dnf install grokbot-linux-port
```

**Ubuntu / Debian:** use the upstream `.deb` — xAI registers its own apt repository when you install it (`downloads.cursor.com/aptrepo`).

**Tarball (any distro):** download `Grok_Bot_<ver>_linux_x64.tar.gz` from [Releases](https://github.com/Nichokas/grokbot-linux-port/releases) and:

```bash
tar -xzf Grok_Bot_*_linux_x64.tar.gz && cd Grok_Bot_*_linux_x64
# chrome-sandbox requires setuid when not using --no-sandbox
sudo chown root:root payload/chrome-sandbox && sudo chmod 4755 payload/chrome-sandbox
./payload/grok-bot
```

## How it works

1. **Detection** (`scripts/detect-version.sh`): polls api2's canonical download manifest (`https://api2.cursor.sh/updates/api/download/stable/linux-<arch>/sand`) once a day. The JSON carries the version directly, so detection is exact.
2. **Repack** (`scripts/repack-deb.sh`): downloads the official `.deb` for each arch, extracts the `/opt` payload and hicolor icon tree, and writes a deterministic `tar.gz` per arch to `dist/`. Determinism means a re-run re-uploading a release asset keeps the published sha256 stable unless upstream bytes actually changed.
3. **Publishing** (`.github/workflows/auto-update.yml`): on a new version — GitHub Release `v<ver>` → bump `VERSION`, the AUR PKGBUILD and the RPM spec → push to `aur.archlinux.org` and POST COPR's custom webhook. Triggering the workflow manually with the current version (`-f version=$(cat VERSION)`) forces a *rebuild*: it re-uploads the artifacts to the existing release and re-syncs the checksums with a `pkgrel`/`Release` bump, without touching `VERSION`.

Manual repack of the current version:

```bash
gh workflow run auto-update.yml -f version=0.30.0   # on GitHub
scripts/repack-deb.sh                                # locally (requires curl, binutils/ar, tar, xz)
```

## Troubleshooting

- `chrome-sandbox` permission denied → run the `chown`/`chmod` above, or launch with `--no-sandbox`.
- On kernels that restrict unprivileged user namespaces without AppArmor (Ubuntu 24.04+), the app needs its AppArmor profile; the `.deb` ships one under `resources/apparmor-profile`. Fedora/Arch kernels don't restrict userns by default, which is why the repack doesn't install it.

## License

This repo does not contain Grok Bot binaries; artifacts are derived at build time from xAI's official Linux distribution. Grok Bot and Electron belong to their respective owners.
