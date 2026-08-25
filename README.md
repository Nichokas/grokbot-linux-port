# Grok Bot Linux Port [WIP]

Port of [Grok Bot](https://downloads.cursor.com/grokbot/stable/win32-x64/) (the official Grok desktop app) for Linux, without Wine. Built by merging the Windows installer (NSIS) with the official Electron 42.1.0 binary for Linux and recompiling the native modules.

It exists because there is no official Linux build.

Found a bug? Please open an issue. I'd really appreciate it!

## Install
Don't see your distro listed above? I'd be happy to add support for your package manager, just open an issue!

**Arch (AUR):**

```bash
yay -S grokbot-linux-port-bin   # precompiled binary, recommended
yay -S grokbot-linux-port       # from source (compiles 6 native modules)
```

**Fedora (COPR):**

```bash
sudo dnf copr enable nichokas/grokbot-linux-port
sudo dnf install grokbot-linux-port
```

**Tarball (any distro):** download `Grok_Bot_<ver>_linux_x64.tar.gz` from [Releases](https://github.com/Nichokas/grokbot-linux-port/releases) and:

```bash
tar -xzf Grok_Bot_*_linux_x64.tar.gz && cd Grok_Bot_*_linux_x64
sudo chown root:root chrome-sandbox && sudo chmod 4755 chrome-sandbox
./grok-bot          # or ./grok-bot --no-sandbox
```

## Versions

| Component | Version |
|-----------|---------|
| Grok Bot  | [`VERSION`](./VERSION) |
| Electron  | 42.1.0 |

## How it works

1. **Detection** (`scripts/detect-version.sh`): upstream doesn't expose a listing or `latest.yml`, so it does HEAD-probing of semver candidates (patches, minors, majors) against `downloads.cursor.com`. The highest one that returns `200` and is newer than `VERSION` triggers a build.
2. **Port** (`scripts/port.sh`): downloads the `Setup.exe`, extracts it with `7z` (without Wine), downloads Electron 42.1.0 for Linux, merges `app.asar`, recompiles the 6 native modules (`better-sqlite3`, `tree-sitter`, etc.) with `@electron/rebuild`, sets `chrome-sandbox` to `4755` and outputs the tarball to `dist/`.
3. **CI** (`.github/workflows/auto-update.yml`): daily at `37 6 * * *` UTC. If there's a new version: build → GitHub Release `v<ver>` => bump `VERSION`, the AUR PKGBUILDs and the RPM spec (`grokbot-linux-port.spec`, consumed by COPR via the `rpkg` source method) => push to `aur.archlinux.org` and POST COPR's custom webhook so the package rebuilds. Requires repo secret `COPR_WEBHOOK_TOKEN` (UUID from the COPR project's Integrations page). Triggering the workflow manually with the current version (`-f version=$(cat VERSION)`) forces a *rebuild*: it re-uploads the artifacts to the existing release and re-syncs the `sha256sums` of the `-bin` package and the spec checksum with a `pkgrel`/`Release` bump, without touching `VERSION`.

Manual build of a specific version:

```bash
gh workflow run auto-update.yml -f version=0.20.0   # on GitHub
scripts/port.sh 0.20.0                               # locally (requires p7zip, curl, unzip, node 22, python3)
```

## Troubleshooting

- `7z: command not found` => install `p7zip-full`.
- `chrome-sandbox` permission denied => run the `chown`/`chmod` above, or launch with `--no-sandbox`.
- `@electron/rebuild` fails => the tarball is still generated; retry with `npx @electron/rebuild --version 42.1.0`.

## License

This repo does not contain Grok Bot binaries; artifacts are derived at build time from the official Windows distribution. Grok Bot and Electron belong to their respective owners.
