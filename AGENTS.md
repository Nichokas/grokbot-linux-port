# AGENTS.md

## What this repo is

Packaging repo for the **Grok Bot Linux port** — the official Windows (NSIS)
desktop app fused with Electron 42.1.0 for Linux, no Wine. This repo holds
the porting scripts, the CI that detects/builds/releases new upstream
versions, and the distro packaging (AUR + Fedora/COPR). The app binaries are
never committed; they are derived at build time.

## Layout

```
VERSION                          current Grok Bot version (single source of truth)
scripts/detect-version.sh        HEAD-probes downloads.cursor.com for new versions
scripts/port.sh                  wine-less port: 7z-extract NSIS, merge Electron, rebuild native modules -> dist/
scripts/update-aur.sh            bumps aur/ PKGBUILDs + .SRCINFO (used by CI release job)
scripts/update-spec.sh           bumps grokbot-linux-port.spec Version/Release/sha256 (used by CI release job)
aur/grokbot-linux-port/          AUR package, builds from source (port.sh at build time)
aur/grokbot-linux-port-bin/      AUR package, prebuilt tarball from GitHub Releases (recommended)
grokbot-linux-port.spec          RPM spec for COPR — prebuilt variant, mirrors the AUR -bin package
.github/workflows/auto-update.yml  daily detect -> build -> release -> AUR publish; PR smoke-builds + lint
```

## Packaging flows

- **AUR**: `update-aur.sh` keeps `pkgver`/`sha256sums`/`.SRCINFO` in sync.
  `-bin` checksum comes from the release job's freshly uploaded bytes
  (`--bin-sum`) to avoid GitHub CDN propagation races.
- **COPR**: the project uses the **rpkg source method** — COPR clones this
  repo and runs `rpkg srpm`, which requires `grokbot-linux-port.spec` at the
  repo root (name must match the repo). `update-spec.sh` keeps
  `Version`/`Release`/sha256 in sync; rebuild resyncs bump `Release`
  (`--bump-release`), fresh versions reset it to 1.
- The spec's `%prep` re-verifies the tarball sha256 so a release re-upload
  fails the RPM build instead of shipping changed bytes under the same NVR.

## Verifying packaging changes locally (Fedora host)

```bash
# RPM: build SRPM + binary RPM against the real release tarball
mkdir -p /tmp/rpm/SOURCES
curl -fSL -o /tmp/rpm/SOURCES/Grok_Bot_$(cat VERSION)_linux_x64.tar.gz \
  https://github.com/Nichokas/grokbot-linux-port/releases/download/v$(cat VERSION)/Grok_Bot_$(cat VERSION)_linux_x64.tar.gz
rpmbuild -bs --define "_topdir /tmp/rpm" grokbot-linux-port.spec
rpmbuild --rebuild --define "_topdir /tmp/rpm" /tmp/rpm/SRPMS/grokbot-linux-port-*.src.rpm
rpm -qpl --dump /tmp/rpm/RPMS/x86_64/*.rpm | grep chrome-sandbox   # must be 0104755 (setuid)

# update-spec.sh dry runs (idempotent no-op when already in sync)
bash scripts/update-spec.sh --sum <sha256> $(cat VERSION)
```

Notes learned the hard way:
- The release tarball contains **no PNGs** (icon lives inside `app.asar`) and
  **no top-level LICENSE** — the spec handles both (conditional icon via
  `-f extra.filelist`, generated LICENSE). Don't re-add unconditional entries.
- The payload is x86_64 ELF: the RPM is arch-dependent on purpose (no
  `BuildArch: noarch`) and disables debuginfo (`%global debug_package %{nil}`)
  because GDB chokes on the bundled Electron binaries.
- `mock` needs the `mock` group / sudo; host `rpmbuild --rebuild` is enough
  for this noarch-free prebuilt package.

## Conventions

- CI commits are made by `github-actions[bot]`; the release job pushes the
  VERSION/AUR/spec bump commit itself — don't hand-edit `VERSION`.
- AUR `.SRCINFO` files are tracked; regenerate via `update-aur.sh` (or
  `makepkg --printsrcinfo`), never by hand.
- Comments explain *why*, not *what* — the workflow and scripts carry dense
  rationale comments; keep that style when editing them.
