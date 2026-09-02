# AGENTS.md

## What this repo is

Packaging repo for the **Grok Bot Linux repack** — xAI's official Linux
`.deb` republished as distro packages (AUR + Fedora/COPR), no porting, no
Wine. Upstream now ships native Linux builds (x64 + arm64, Electron 42 with
its native modules compiled), so this repo resolves the official `.deb`
through api2's canonical manifest, repacks the `/opt` payload verbatim as a
deterministic tarball on GitHub Releases, and feeds that tarball to the
distro packaging. The app binaries are never committed; they are derived at
build time.

## Layout

```
VERSION                          current Grok Bot version (single source of truth)
scripts/detect-version.sh        reads the current version from api2's JSON manifest
scripts/repack-deb.sh            official .deb -> deterministic release tarball -> dist/
scripts/update-aur.sh            bumps aur/ PKGBUILD + .SRCINFO (used by CI release job)
scripts/update-spec.sh           bumps grokbot-linux-port.spec Version/Release/sha256 (used by CI release job)
aur/grokbot-linux-port-bin/      AUR package, prebuilt tarball from GitHub Releases
grokbot-linux-port.spec          RPM spec for COPR — mirrors the AUR -bin package
.github/workflows/auto-update.yml  daily detect -> repack -> release -> AUR publish; PR smoke-builds + lint
.github/workflows/copr-publish.yml  POST COPR custom webhook when the spec lands on main
```

## Upstream surfaces

- **Canonical manifest**: `https://api2.cursor.sh/updates/api/download/stable/linux-<arch>/sand`
  returns JSON with `version`, `commitSha`, `debUrl`, `rpmUrl`,
  `downloadUrl` (AppImage). The app name is `sand` (per the deb's
  `Provides: sand`); `grok-bot` is rejected by that route. The versioned
  302 links (`/updates/download/stable/linux-<arch>/grok-bot-<hash>`) embed
  per-arch hashes that rotate without a schedule — never bake them into
  anything; resolve through the JSON instead.
- The `.deb` is FPM-built: payload at `/opt/Grok Bot` (note the space),
  hicolor icons at `/usr/share/icons/hicolor` (16..512), a desktop entry,
  and a `postinst` that registers xAI's own apt repo
  (`downloads.cursor.com/aptrepo`). The repack drops the postinst — this
  repo's packages are the distribution channel, not a bridge to xAI's.
- `chrome-sandbox` arrives mode 0755 (the postinst chmods 4755 at install
  time); `repack-deb.sh` bakes 4755 into the tarball so consumers get it
  without a post-install step.

## Release tarball layout

`Grok_Bot_<ver>_linux_<arch>.tar.gz` (x64|arm64), deterministic bytes
(`tar --sort=name --mtime=@0 --owner=0 --group=0`, `gzip -n`):

```
Grok_Bot_<ver>_linux_<arch>/
├── payload/          the .deb's /opt/Grok Bot tree, verbatim
└── hicolor/          the .deb's /usr/share/icons/hicolor tree
```

The payload dir name mirrors the old port tarball so consumers
(`payload_dir` in the spec, `staged` in the PKGBUILD) stayed unchanged.
Repack guards: deb control `Version:` must match the api2 version, the
payload ELF `e_machine` must match the arch label (0x3e x64, 0xb7 arm64),
`chrome-sandbox` must keep its setuid bit in the produced tarball, and no
non-world-readable directory may ship.

## Packaging flows

- **Architectures**: x86_64 and aarch64. The repack only copies bytes —
  nothing is executed or linked — so both arches build on a single x64
  runner; the per-arch runner matrix existed for the native-module
  rebuilds of the win32 porting pipeline and is gone. Downstream stays
  per-arch: AUR `-bin` uses `sha256sums_x86_64`/`sha256sums_aarch64`, the
  spec carries both tarballs in `Source0`/`Source1` and `%ifarch`-selects
  one.
- **AUR**: `update-aur.sh` keeps `pkgver`/`sha256sums`/`.SRCINFO` in sync.
  `-bin` checksum comes from the release job's freshly uploaded bytes
  (`--bin-sum-*`) to avoid GitHub CDN propagation races. The bump is
  skipped unless **both** arch sums are present, so a half-published job
  can't leave one branch with a stale digest. The from-source
  `grokbot-linux-port` package was removed with the porting pipeline.
- **COPR**: the project uses the **rpkg source method** — COPR clones this
  repo and runs `rpkg srpm`, which requires `grokbot-linux-port.spec` at
  the repo root (name must match the repo). `update-spec.sh` keeps
  `Version`/`Release`/sha256 in sync; rebuild resyncs bump `Release`
  (`--bump-release`), fresh versions reset it to 1. After the spec bump is
  pushed to main, `copr-publish.yml` POSTs COPR's custom webhook. Set repo
  secret `COPR_WEBHOOK_TOKEN` to the UUID from COPR → Integrations.
- The spec's `%prep` re-verifies the tarball sha256 so a release re-upload
  fails the RPM build instead of shipping changed bytes under the same NVR.
- **Debian/Ubuntu**: upstream serves the `.deb` and registers its own apt
  repo itself — the PPA pipeline this repo used to carry was removed when
  the porting pipeline was (see the repo's closed PRs for the history).

## Verifying packaging changes locally (Fedora host)

```bash
# Repack both arches against live upstream
bash scripts/repack-deb.sh --version "$(cat VERSION)"

# RPM: build both arch RPMs against the real release tarball
rm -rf /tmp/rpm && mkdir -p /tmp/rpm/SOURCES
cp dist/Grok_Bot_*_linux_*.tar.gz /tmp/rpm/SOURCES/
rpmbuild -bb --target x86_64  --define "_topdir /tmp/rpm" grokbot-linux-port.spec
rpmbuild -bb --target aarch64 --define "_topdir /tmp/rpm" grokbot-linux-port.spec
rpm -qpl --dump /tmp/rpm/RPMS/x86_64/*.rpm | grep chrome-sandbox   # must be 0104755 (setuid)

# AUR: canonical .SRCINFO (makepkg is not on Fedora — container)
docker run --rm -v "$PWD/aur/grokbot-linux-port-bin:/pkg:rw,z" archlinux:base-devel \
  sh -c "useradd -m b 2>/dev/null; cp -r /pkg /tmp/p && chown -R b /tmp/p && cd /tmp/p && sudo -u b makepkg --printsrcinfo > /pkg/.SRCINFO"

# update-spec.sh dry runs (idempotent no-op when already in sync)
bash scripts/update-spec.sh --sum-x64 <sha256-x64> --sum-arm64 <sha256-arm64> $(cat VERSION)
```

Notes learned the hard way:
- The `.deb`'s hicolor tree ships under `usr/share/icons/hicolor`; the
  tarball moves it to `hicolor/` at the root. When installing from the
  tarball, re-prefix with `icons/` — a plain
  `install -Dm644 hicolor/… %{buildroot}%{_datadir}/hicolor/…` ships the
  icon at `/usr/share/hicolor` where nothing finds it. The CI spec-smoke
  exists to catch exactly this class of `%install` bug.
- The payload installs verbatim; `chrome-sandbox` mode 4755 is baked in by
  the repack. Do not add mode-normalisation passes or MZ-header guards —
  those existed because the win32 payload's native modules could ship as
  PE binaries; the official .deb's are Linux ELF by construction.
- Every rpm scriptlet starts fresh in the builddir, so `%prep`'s `cd` does
  not carry into `%install`. Both re-enter `%{payload_dir}` (the `%ifarch`-
  selected tarball dir); `extra.filelist` and `LICENSE` stay in the
  builddir because that is where `%files -f` and `%license` look.
  `rpmbuild -bs` never runs those scriptlets, which is why the `spec-lint`
  job also builds both arch RPMs against a stub payload — that smoke is
  the regression test for anything touching `%prep`/`%install`/`%files`.
- `mock` needs the `mock` group / sudo; host `rpmbuild -bb --target
  aarch64` is enough for this no-build prebuilt package.
- `grep -q` in a `set -o pipefail` pipeline SIGPIPEs the upstream command
  (tar/rpm exit 141) after its first hit; list to a file first and grep
  the file. This bit the spec-smoke's filelist checks and the repack's
  setuid assertion.

## Conventions

- CI commits are made by `github-actions[bot]`; the release job pushes the
  VERSION/AUR/spec bump commit itself — don't hand-edit `VERSION`.
- AUR `.SRCINFO` files are tracked; regenerate via `update-aur.sh` (or
  `makepkg --printsrcinfo`), never by hand.
- Comments explain *why*, not *what* — the workflow and scripts carry dense
  rationale comments; keep that style when editing them.
