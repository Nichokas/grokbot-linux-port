# grokbot-linux-port.spec — Fedora/COPR packaging (prebuilt variant)
#
# Mirrors aur/grokbot-linux-port-bin: the payload is the prebuilt Linux
# tarball published on GitHub Releases by .github/workflows/auto-update.yml.
# scripts/update-spec.sh keeps Version/Release and the sha256 in sync with
# each release (and bumps Release on rebuild resyncs), the same way
# scripts/update-aur.sh maintains the AUR PKGBUILDs.
#
# COPR builds this via the "rpkg" source method: it clones the repo and runs
# `rpkg srpm`, which expects this spec at the repository root.

Name:           grokbot-linux-port
Version:        0.30.0
Release:        1%{?dist}
Summary:        Grok Bot desktop — wine-less Linux port (prebuilt tarball)

# Upstream EULA lives inside resources/app.asar; see the installed LICENSE.
License:        Proprietary
URL:            https://github.com/Nichokas/grokbot-linux-port
Source0:        %{url}/releases/download/v%{version}/Grok_Bot_%{version}_linux_x64.tar.gz
Source1:        %{url}/releases/download/v%{version}/Grok_Bot_%{version}_linux_arm64.tar.gz

# The tarball is produced by CI for both linux-x64 and linux-arm64 (see the
# build matrix in auto-update.yml) and carries prebuilt ELF binaries for the
# matching arch. The SRPM carries BOTH tarballs in Source0/Source1; each
# chroot's %setup extracts only the matching one based on _target_arch. This
# way a single `rpkg srpm` produces an SRPM that COPR can fan out across its
# x86_64/aarch64 chroots without each needing to resolve the other arch's URL.
# No ExclusiveArch: the package is arch-dependent on purpose, but it must be
# buildable on whichever arch the chroot is.
%global debug_package %{nil}

# Payload dir, selected per build arch. Single source of truth for the tarball
# directory name so %prep and %install cannot disagree about the working dir.
%ifarch aarch64
%global payload_dir Grok_Bot_%{version}_linux_arm64
%else
%global payload_dir Grok_Bot_%{version}_linux_x64
%endif

BuildRequires:  coreutils
BuildRequires:  findutils
BuildRequires:  tar
BuildRequires:  python3

# Runtime libraries for Electron 42 (names translated from the AUR depends).
Requires:       alsa-lib
Requires:       at-spi2-core
Requires:       cairo
Requires:       expat
Requires:       gtk3
Requires:       hicolor-icon-theme
Requires:       libdrm
Requires:       libXcomposite
Requires:       libXdamage
Requires:       libXfixes
Requires:       libXrandr
Requires:       libXScrnSaver
Requires:       libXtst
Requires:       libxkbcommon
Requires:       mesa-libEGL
Requires:       mesa-libGL
Requires:       mesa-libgbm
Requires:       nss
Requires:       pango

Provides:       grok-bot = %{version}-%{release}
Provides:       grokbot = %{version}-%{release}

%description
Grok Bot desktop agent for Linux without Wine: the official Windows (NSIS)
payload fused with Electron 42.1.0 and native modules rebuilt for Linux.
This package installs the prebuilt tarball published on GitHub Releases by
the grokbot-linux-port CI.

%prep
# Refuse arches that carry no tarball: packaging the x64 payload under an
# e.g. ppc64le RPM would dlopen-fail at runtime.
%ifnarch x86_64 aarch64
echo "error: grokbot-linux-port has no payload for %{_target_cpu}" >&2
exit 1
%endif
# Source0 is x64, Source1 is arm64; each build extracts only its matching
# tarball. %ifarch tests the chroot's real build arch; the setup macro's
# per-source unpack flags proved unreliable across rpm versions (rpm 6
# unpacks Source0 alongside -b 1), so the extraction is spelled out.
%ifarch aarch64
rm -rf %{payload_dir}
tar -xf %{SOURCE1}
echo "67cb0332c40f5e3140f9f709c4c26065df00b9df5c4e53f15ad14aef44fafc9d  %{_sourcedir}/Grok_Bot_0.30.0_linux_arm64.tar.gz" | sha256sum -c -
cd %{payload_dir}
%else
rm -rf %{payload_dir}
tar -xf %{SOURCE0}
echo "3623162e9442c504c43fb6df144e7aeecf9b5eb831040c70827adc98b5b49597  %{_sourcedir}/Grok_Bot_0.30.0_linux_x64.tar.gz" | sha256sum -c -
cd %{payload_dir}
%endif

# The tarball keeps NSIS-derived restrictive modes (drwx------ on
# app.asar.unpacked); normalise so the installed tree is world-readable,
# matching the AUR package.
chmod -R u+rwX,go+rX,go-w .

%install
# Each scriptlet starts fresh in the builddir, so %prep's cd does not carry
# over. Without re-entering the payload dir, `cp -a .` copies the builddir
# (which contains BUILDROOT) into itself. %files resolves -f and %license
# relative to the builddir, so keep those two artifacts there.
builddir="$(pwd)"
cd %{payload_dir}

install -dm755 %{buildroot}/opt/%{name} \
               %{buildroot}%{_bindir} \
               %{buildroot}%{_datadir}/applications \
               %{buildroot}%{_datadir}/icons/hicolor/256x256/apps \
               %{buildroot}%{_licensedir}/%{name}

cp -a . %{buildroot}/opt/%{name}/

# Some tarballs keep the electron binary named 'electron'; normalise.
if [ ! -x %{buildroot}/opt/%{name}/grok-bot ] && [ -x %{buildroot}/opt/%{name}/electron ]; then
  mv %{buildroot}/opt/%{name}/electron %{buildroot}/opt/%{name}/grok-bot
fi
chmod +x %{buildroot}/opt/%{name}/grok-bot

ln -s /opt/%{name}/grok-bot %{buildroot}%{_bindir}/grok-bot
ln -s /opt/%{name}/grok-bot %{buildroot}%{_bindir}/grokbot

cat > %{buildroot}%{_datadir}/applications/grok-bot.desktop <<'DESKTOP'
[Desktop Entry]
Name=Grok Bot
GenericName=Grok Bot
Comment=Grok Bot desktop agent (Linux port)
Exec=/opt/grokbot-linux-port/grok-bot %U
Icon=grok-bot
Type=Application
Categories=Utility;Development;
StartupWMClass=grok-bot
MimeType=x-scheme-handler/grokbot;
Terminal=false
DESKTOP

# The desktop entry always ships; the icon joins the same filelist only when
# a PNG is found. Current tarballs keep it inside packed app.asar, so a
# filesystem hunt fails — extract from asar in that case. A -f filelist must
# contain at least one real entry, hence anchoring it on the desktop file.
echo "%{_datadir}/applications/grok-bot.desktop" > "${builddir}/extra.filelist"
icon=""
for cand in \
  grok-bot.png \
  resources/app.asar.unpacked/dist/renderer/assets/app-icon-*.png \
  resources/app.asar.unpacked/*.png
do
  [ -f "${cand}" ] && { icon="${cand}"; break; }
done
if [ -z "${icon}" ]; then
  icon="$(find . -name 'app-icon*.png' -print -quit || true)"
fi
if [ -z "${icon}" ] && [ -f resources/app.asar ]; then
  python3 - resources/app.asar grok-bot-from-asar.png <<'PY' && icon=grok-bot-from-asar.png
import json, pathlib, struct, sys

def walk(node, prefix=""):
    for name, meta in node.get("files", {}).items():
        path = f"{prefix}/{name}" if prefix else name
        if "files" in meta:
            yield from walk(meta, path)
        else:
            yield path, meta

# Best-effort extraction: the %files icon entry is conditional anyway, so
# keep failures as one-line errors instead of tracebacks.
try:
    asar, dest = sys.argv[1], sys.argv[2]
    with open(asar, "rb") as fh:
        if struct.unpack("<I", fh.read(4))[0] != 4:
            raise SystemExit("bad asar pickle")
        header_size = struct.unpack("<I", fh.read(4))[0]
        header_pickle = fh.read(header_size)
        str_len = struct.unpack_from("<I", header_pickle, 4)[0]
        header = json.loads(header_pickle[8:8 + str_len])
        hits = [
            (p, m) for p, m in walk(header)
            if p.rsplit("/", 1)[-1].startswith("app-icon") and p.endswith(".png") and "offset" in m
        ]
        if not hits:
            raise SystemExit("no app-icon*.png in asar")
        path, meta = max(hits, key=lambda item: int(item[1]["size"]))
        fh.seek(8 + header_size + int(meta["offset"]))
        blob = fh.read(int(meta["size"]))
        if len(blob) != int(meta["size"]):
            raise SystemExit(f"error: {path} is truncated")
        if blob[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit("not a PNG")
        pathlib.Path(dest).write_bytes(blob)
except Exception as exc:
    raise SystemExit(f"error: {exc}")
PY
fi
if [ -n "${icon}" ] && [ -f "${icon}" ]; then
  install -m644 "${icon}" %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/grok-bot.png
  echo "%{_datadir}/icons/hicolor/256x256/apps/grok-bot.png" >> "${builddir}/extra.filelist"
fi

# Upstream EULA lives inside app.asar; ship a pointer file as the license.
cat > "${builddir}/LICENSE" <<'LICENSE'
Grok Bot is proprietary software. This package fetches the prebuilt Linux
tarball published at https://github.com/Nichokas/grokbot-linux-port/releases.
See upstream terms at https://grok.com and inside resources/app.asar.
LICENSE

# Chromium's user namespace sandbox needs setuid when kernel.unprivileged_
# userns_clone is off; the wrapper falls back to --no-sandbox otherwise.
if [ -f %{buildroot}/opt/%{name}/chrome-sandbox ]; then
  chmod 4755 %{buildroot}/opt/%{name}/chrome-sandbox
fi

%files -f extra.filelist
%license LICENSE
# chrome-sandbox is packaged with the 4755 mode set in %install (rpmbuild
# preserves buildroot file modes; no %defattr override in this spec).
/opt/%{name}/
%{_bindir}/grok-bot
%{_bindir}/grokbot

%changelog
* Sat Aug 29 2026 Nichokas <nichokas@users.noreply.github.com> - 0.30.0-1
- Sync with upstream release v0.30.0 (x64 sha256 3623162e9442c504c43fb6df144e7aeecf9b5eb831040c70827adc98b5b49597) (arm64 sha256 67cb0332c40f5e3140f9f709c4c26065df00b9df5c4e53f15ad14aef44fafc9d).

* Thu Aug 27 2026 Nichokas <nichokas@users.noreply.github.com> - 0.29.0-1
- Sync with upstream release v0.29.0 (tarball sha256 0ed63f0beae1d5a61ec7b1ebb0d1d1931522c1c28ced0532c451cf4f294b3912).

* Wed Aug 26 2026 Nichokas <nichokas@users.noreply.github.com> - 0.27.0-1
- Sync with upstream release v0.27.0 (tarball sha256 4302bd55c2350c33c551e58a7bdb7863b6bcfaf127ea79334ec0be242dcdbbf7).

* Tue Aug 25 2026 Nichokas <nichokas@users.noreply.github.com> - 0.25.0-2
- Extract grok-bot desktop icon from packed app.asar when no loose PNG is present.

* Tue Aug 25 2026 Nichokas <nichokas@users.noreply.github.com> - 0.25.0-1
- Sync with upstream release v0.25.0 (tarball sha256 f4405f7ee46d91cc76e9b09bb3980673c7ddef01fb22b67f0c8007d02327fe85).

* Fri Aug 21 2026 Nichokas <nichokas@users.noreply.github.com> - 0.24.0-1
- Sync with upstream release v0.24.0 (tarball sha256 f6b6495f9398a9d60702a282b404ac52e2b1c1c345d3ba81bbbd242e49ea6aad).

* Thu Aug 20 2026 Nichokas <nichokas@users.noreply.github.com> - 0.23.0-1
- Sync with upstream release v0.23.0 (tarball sha256 0cd3c9ac2f24e53cf021cfef4613db6902857262a918471033975d1ba5d7003c).

* Sun Aug 16 2026 Nichokas <nichokas@users.noreply.github.com> - 0.20.0-1
- Initial RPM packaging (prebuilt tarball variant, mirrors the AUR -bin package).
