# AGENTS.md

## What this repo is

Packaging repo for the **Grok Bot Linux port** — the official Windows (NSIS)
desktop app fused with Electron 42.1.0 for Linux, no Wine. This repo holds
the porting scripts, the CI that detects/builds/releases new upstream
versions, and the distro packaging (AUR + Fedora/COPR + Ubuntu/PPA). The app binaries are
never committed; they are derived at build time.

## Layout

```
VERSION                          current Grok Bot version (single source of truth)
scripts/detect-version.sh        HEAD-probes downloads.cursor.com for new versions
scripts/port.sh                  wine-less port: 7z-extract NSIS, merge Electron, rebuild native modules -> dist/
scripts/update-aur.sh            bumps aur/ PKGBUILDs + .SRCINFO (used by CI release job)
scripts/update-spec.sh           bumps grokbot-linux-port.spec Version/Release/sha256 (used by CI release job)
scripts/build-deb.sh             assembles Debian source packages per Ubuntu series (native, no network on Launchpad)
aur/grokbot-linux-port/          AUR package, builds from source (port.sh at build time)
aur/grokbot-linux-port-bin/      AUR package, prebuilt tarball from GitHub Releases (recommended)
grokbot-linux-port.spec          RPM spec for COPR — prebuilt variant, mirrors the AUR -bin package
.github/workflows/auto-update.yml  daily detect -> build -> release -> AUR publish; PR smoke-builds + lint
.github/workflows/copr-publish.yml POST COPR custom webhook when the spec lands on main
.github/workflows/ppa-publish.yml  build Debian source packages + dput to Launchpad PPA per series
```

## Packaging flows

- **Architectures**: x86_64 and aarch64. `port.sh` builds natively (native
  modules are compiled against the target Electron ABI, no cross toolchain),
  so `auto-update.yml`'s build matrix pairs each arch with a runner of that
  arch — `namespace-profile-grokbot` (x64) and `namespace-profile-grokbot-arm`
  (arm64). Every downstream leg is per-arch: AUR `-bin` uses
  `sha256sums_x86_64`/`sha256sums_aarch64`, the spec carries both tarballs in
  `Source0`/`Source1` and `%ifarch`-selects one, and `ppa-publish.yml` runs an
  `amd64`/`arm64` matrix. The win32 payload is always fetched from
  `win32-x64` — it only contributes JS and assets, since every native binary
  is re-sourced for `linux-<target>`.
- **AUR**: `update-aur.sh` keeps `pkgver`/`sha256sums`/`.SRCINFO` in sync.
  `-bin` checksum comes from the release job's freshly uploaded bytes
  (`--bin-sum`) to avoid GitHub CDN propagation races. The `-bin` bump is
  skipped unless **both** arch sums are present, so a half-published matrix
  can't leave one branch with a stale digest.
- **COPR**: the project uses the **rpkg source method** — COPR clones this
  repo and runs `rpkg srpm`, which requires `grokbot-linux-port.spec` at the
  repo root (name must match the repo). `update-spec.sh` keeps
  `Version`/`Release`/sha256 in sync; rebuild resyncs bump `Release`
  (`--bump-release`), fresh versions reset it to 1. After the spec bump is
  pushed to main, `copr-publish.yml` POSTs COPR's custom webhook. Set repo
  secret `COPR_WEBHOOK_TOKEN` to the UUID from COPR → Integrations.
- **Ubuntu/PPA**: `build-deb.sh` generates native Debian source packages
  (`3.0 (native)`) with the release tarball as the entire source — Launchpad
  builders have no network, so every byte must ship inside the source package.
  - Target series: **noble (24.04)** and **resolute (26.04)** only.
  - Per-series versioning: `<ver>~ppa<N>~<series>1`, where N mirrors the
    spec's `Release:` counter (update-spec.sh bumps it on rebuild resyncs),
    so re-uploaded bytes get a fresh Debian version instead of the duplicate
    Launchpad rejects.
  - Static deps with t64 names (`libgtk-3-0t64 | libgtk-3-0` etc.); no
    `dpkg-shlibdeps` — the builder cannot resolve dynamically.
  - `debian/rules` no-ops `dh_dwz`, `dh_strip`, `dh_makeshlibs` and
    `dh_shlibdeps`: the /opt payload is a prebuilt vendor bundle with private
    libs, `dwz` aborts on Electron's `.debug_addr`/missing `.debug_info` (this
    killed every `0.30.0~ppa1` build), and `dh_makeshlibs` would advertise the
    bundled libvulkan/libffmpeg as provided by this package. Same intent as the
    spec's `%global debug_package %{nil}` — the .deb ships the tarball bytes
    unmodified.
  - `deb-lint` (PR gate) builds the stub *binary* package too, since the
    Launchpad-only failures live in `dh binary`; its stub chrome-sandbox is a
    real ELF with split DWARF on purpose, and it asserts no `shlibs` file and a
    setuid chrome-sandbox. Keep it that way — a touch'd stub proves nothing.
  - GPG signing required: the `PPA_GPG_PRIVATE_KEY` secret (armored key, no
    passphrase, registered in Launchpad) signs `.dsc`/`.changes`; unsigned
    uploads are rejected. `ppa-publish.yml` runs `dput
    ppa:nichito/grokbot-linux-port <series>/*_source.changes` with one retry.
  - Hook-up: `auto-update.yml` fires a `ppa-rebuild` repository_dispatch after
    the spec bump lands on the default branch (same reason as `copr-rebuild`
    — GITHUB_TOKEN pushes suppress push events).
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

# Debian source package (PPA): builds against the release tarball, no network in Launchpad
# Requires debhelper + devscripts on the host
curl -fSL -o /tmp/Grok_Bot_$(cat VERSION)_linux_x64.tar.gz \
  https://github.com/Nichokas/grokbot-linux-port/releases/download/v$(cat VERSION)/Grok_Bot_$(cat VERSION)_linux_x64.tar.gz
bash scripts/build-deb.sh --tarball /tmp/Grok_Bot_$(cat VERSION)_linux_x64.tar.gz --sha256 $(sha256sum /tmp/Grok_Bot_$(cat VERSION)_linux_x64.tar.gz | awk '{print $1}') --series noble --out-dir /tmp/ppa-out
cat /tmp/ppa-out/noble/*.dsc | head -n 20
```

Notes learned the hard way:
- The release tarball historically contained **no PNGs** (the icon lives
  inside packed `app.asar`, not `app.asar.unpacked`) and **no top-level
  LICENSE**. `port.sh` now extracts `grok-bot.png` to the tarball root;
  the AUR PKGBUILDs and the spec also extract from asar so already-published
  tarballs still ship an icon. Keep the spec's icon filelist conditional —
  extraction is best-effort if the asar layout changes. Don't re-add
  unconditional icon entries. The LICENSE file is generated by the spec.
- The payload is x86_64 ELF: the RPM is arch-dependent on purpose (no
  `BuildArch: noarch`) and disables debuginfo (`%global debug_package %{nil}`)
  because GDB chokes on the bundled Electron binaries.
- `mock` needs the `mock` group / sudo; host `rpmbuild --rebuild` is enough
  for this noarch-free prebuilt package.
- Every rpm scriptlet starts fresh in the builddir, so `%prep`'s `cd` does not
  carry into `%install`. Both re-enter `%{payload_dir}` (the `%ifarch`-selected
  tarball dir); `extra.filelist` and `LICENSE` stay in the builddir because
  that is where `%files -f` and `%license` look. `rpmbuild -bs` never runs
  those scriptlets, which is why the `spec-lint` job also builds both arch
  RPMs against a stub payload — that smoke is the regression test for anything
  touching `%prep`/`%install`/`%files`.

## Conventions

- CI commits are made by `github-actions[bot]`; the release job pushes the
  VERSION/AUR/spec bump commit itself — don't hand-edit `VERSION`.
- AUR `.SRCINFO` files are tracked; regenerate via `update-aur.sh` (or
  `makepkg --printsrcinfo`), never by hand.
- Comments explain *why*, not *what* — the workflow and scripts carry dense
  rationale comments; keep that style when editing them.
