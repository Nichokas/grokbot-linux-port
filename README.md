# Grok Bot — Linux Port

A wine-less Linux port of [Grok Bot](https://downloads.cursor.com/grokbot/stable/win32-x64/) — the official Grok desktop application — produced by fusing the Windows NSIS distribution with the upstream Electron 42.1.0 Linux binary and rebuilding native modules against the target ABI.

The port exists because no official Linux build is distributed.  The upstream artefacts are deterministic per version:

- Windows: `https://downloads.cursor.com/grokbot/stable/win32-x64/<version>/Grok_Bot_<version>_Setup.exe`
- macOS:   `https://downloads.cursor.com/grokbot/stable/darwin-x64/<version>/Grok_Bot_<version>_x64.dmg`

Example (verified 2026-08-14):

- `https://downloads.cursor.com/grokbot/stable/win32-x64/0.19.0/Grok_Bot_0.19.0_Setup.exe`
- `https://downloads.cursor.com/grokbot/stable/win32-x64/0.18.0/Grok_Bot_0.18.0_Setup.exe`

The Linux build is derived exclusively from the Windows installer; the macOS artefact is probed only as a cross-platform existence signal.

## Current versions

| Component | Version |
|-----------|---------|
| Grok Bot (base) | 0.18.0 (see [`VERSION`](./VERSION)) |
| Grok Bot (latest probed) | 0.19.0 (as of 2026-08-14) |
| Electron | 42.1.0 |

## How it works

### Version discovery (`scripts/detect-version.sh`)

Upstream exposes no S3 `?list-type=2` listing (returns `AccessDenied`) and no `latest.yml` manifest (403).  Discovery therefore proceeds by **version-anchored HEAD-probing**:

1. Read the current base version from the [`VERSION`](./VERSION) file (e.g. `0.18.0`).
2. Generate an ordered candidate set of ~25 semver versions covering non-linear jumps:
   - Patch sweep `x.y.(z+1) .. x.y.(z+10)` — the common case.
   - Minor sweep `x.(y+1).0 .. x.(y+10).0` — required because Grok Bot jumps such as `0.18.0 -> 0.19.0` are invisible to a patch-only probe.
   - Next-patch of each upcoming minor `x.(y+n).1` — catches `0.19.1`-style releases.
   - Major sweep `(x+1).0.0`.
3. Deduplicate, sort descending with `sort -V -r`, then `HEAD`-probe each:
   ```bash
   curl --head --fail --silent --location --max-time 10 --retry 2 \
     -o /dev/null -w "%{http_code}" \
     "https://downloads.cursor.com/grokbot/stable/win32-x64/<ver>/Grok_Bot_<ver>_Setup.exe"
   ```
   HTTP `200` denotes existence; `403` denotes absence.  An optional `darwin-x64` probe is performed for cross-platform confirmation when the Windows probe fails (propagation lag).
4. Select the highest passing candidate via `sort -V | tail -n 1`.  If that candidate is strictly greater than the base (also via `sort -V`), it is deemed new and triggers a build.

The probe uses `HEAD` rather than `GET` to minimise bandwidth.  Candidate count is bounded to keep daily Actions wall time well under the free-tier limits.

### Port assembly (`scripts/port.sh`)

Given a verified version, `port.sh` performs the wine-less port:

1. Download the Windows NSIS installer from the URL above.
2. Extract without Wine: `7z x Grok_Bot_<ver>_Setup.exe` then `7z x app-64.7z` (fallback `app-32.7z` for historical installers).  No Wine or Windows execution is ever invoked.
3. Verify `resources/app.asar` and `resources/app.asar.unpacked`.
4. Download `electron-v42.1.0-linux-x64.zip` from `https://github.com/electron/electron/releases/download/v42.1.0/electron-v42.1.0-linux-x64.zip` and extract it.
5. Stage `Grok_Bot_<ver>_linux_x64/` — Electron binary (renamed `grok-bot`), `chrome-sandbox`, `locales/`, `*.pak`, `resources/app.asar` + `app.asar.unpacked`.
6. Rebuild the six native modules against Electron 42.1.0:
   `better-sqlite3`, `cursor-proclist`, `tree-sitter`, `tree-sitter-bash`, `tree-chunk-napi`, `whichlang-node`
   via `npx @electron/rebuild --version 42.1.0` (best-effort; the payload is still produced when the rebuild is unavailable).
7. Fix `chrome-sandbox` to `root:root 4755` when running as root; otherwise emit a warning with remediation instructions.
8. Emit artefacts into `dist/`:
   - `Grok_Bot_<ver>_linux_x64.tar.gz` — **always** produced (canonical portable artefact).
   - `.deb` — best-effort via `electron-installer-debian`.
   - `.AppImage` — best-effort note; requires `electron-builder` with a full build configuration.

### Automation (`.github/workflows/auto-update.yml`)

| Job | Trigger | Function |
|-----|---------|----------|
| `detect-version` | always | Runs `detect-version.sh`; exports `version` and `is_new`. |
| `build` | `is_new == 'true'` | Runs `port.sh <version>` on `ubuntu-22.04` (arch matrix `x64`; extend to `x64, arm64` for ARM). |
| `release` | `is_new == 'true'` | Creates a GitHub Release at `v<version>` via `softprops/action-gh-release`, uploads artefacts, commits the bumped `VERSION` file. |

**Schedule:** daily `37 6 * * *` UTC — offset from `:00` and `:30` to avoid the thundering herd on shared runners and on the upstream origin.

**Concurrency:** group `auto-update`, `cancel-in-progress: false` (releases are not cancelled mid-flight).

**Permissions:** top-level `contents: read`; `release` job elevates to `contents: write` for tag and commit.

**Actions used:** `actions/checkout@v4`, `actions/setup-node@v4` (Node 22), `actions/cache@v4`, `actions/upload-artifact@v4`, `actions/download-artifact@v4`, `softprops/action-gh-release@v2`.

## Manual dispatch

To build a specific version without waiting for the daily probe, trigger the workflow manually:

- **GitHub UI:** Actions → *Auto Update* → *Run workflow* → enter `version` (e.g. `0.19.0`).
- **CLI:**
  ```bash
  gh workflow run auto-update.yml -f version=0.19.0
  ```
- **Local (no Actions):**
  ```bash
  # Verify and report the version (dispatch bypasses candidate probing)
  scripts/detect-version.sh 0.19.0
  INPUT_VERSION=0.19.0 scripts/detect-version.sh

  # Build that version
  scripts/port.sh 0.19.0
  ls -lh dist/
  ```

When a dispatched version is supplied, `detect-version.sh` validates it with a direct `HEAD` probe and treats a `200` as authoritative irrespective of the candidate set.  If no candidate exceeds the base for `N` consecutive days, no release is created; the condition is visible in the Actions logs and can be escalated to an issue manually.

A direct `VERSION` file edit is also supported:

```bash
echo "0.19.0" > VERSION
git add VERSION && git commit -m "chore: bump VERSION to 0.19.0"
```

## Local build

Prerequisites:

```bash
sudo apt-get install -y p7zip-full curl unzip build-essential python3
# Node 22 — via nvm, fnm, or nodesource
node --version  # should report v22.x
```

Steps:

```bash
git clone <this-repo> && cd grokbot-linux-port

# 1. Detect (or pin) the version
scripts/detect-version.sh              # autonomous
scripts/detect-version.sh 0.19.0       # pinned

# 2. Build
scripts/port.sh 0.19.0

# 3. Inspect
ls -lh dist/
# dist/Grok_Bot_0.19.0_linux_x64.tar.gz  — portable archive

# 4. Run
tar -xzf dist/Grok_Bot_0.19.0_linux_x64.tar.gz
cd Grok_Bot_0.19.0_linux_x64
# chrome-sandbox requires setuid unless --no-sandbox is used
sudo chown root:root chrome-sandbox && sudo chmod 4755 chrome-sandbox
./grok-bot
# or, without sandbox privileges:
./grok-bot --no-sandbox
```

`port.sh` options:

```bash
scripts/port.sh --help
scripts/port.sh --electron-version 42.1.0 0.19.0
```

Environment:

- `GROKBOT_KEEP_WORKDIR=1` — retain the temporary work directory for debugging.

## Artefact matrix

| Artefact | Produced | Notes |
|----------|----------|-------|
| `Grok_Bot_<ver>_linux_x64.tar.gz` | always | Canonical. Extract and run. |
| `Grok_Bot_<ver>_linux_x64.deb` | best-effort | Requires `electron-installer-debian`. |
| `Grok_Bot_<ver>_linux_x64.AppImage` | best-effort | Requires `electron-builder` with full config. |

Only `x64` is built in CI; `arm64` can be enabled by expanding the `arch` matrix in `auto-update.yml` and mapping the Electron download URL accordingly.

## Troubleshooting

- `7z: command not found` — install `p7zip-full` (`7z`, `7za`, `7zr` are all accepted).
- `@electron/rebuild` fails — the six native modules have not been rebuilt for Linux; the tarball is still produced but native functionality (SQLite, tree-sitter, etc.) will malfunction until rebuilt.  Re-run manually: `npx @electron/rebuild --version 42.1.0`.
- `chrome-sandbox` permission denied — run the `chown`/`chmod` command above, or launch with `--no-sandbox` (reduces isolation).

## Licence and provenance

This repository contains no upstream Grok Bot binaries.  Artefacts are derived at build time from the official Windows distribution.  Grok Bot and Electron are the property of their respective owners.
