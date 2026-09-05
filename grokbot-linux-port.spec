# grokbot-linux-port.spec — Fedora/COPR packaging (repack variant)
#
# Mirrors aur/grokbot-linux-port-bin: the payload is the prebuilt Linux
# tarball published on GitHub Releases by .github/workflows/auto-update.yml,
# itself repacked verbatim from xAI's official Linux .deb by
# scripts/repack-deb.sh. scripts/update-spec.sh keeps Version/Release and
# the sha256 in sync with each release (and bumps Release on rebuild
# resyncs), the same way scripts/update-aur.sh maintains the AUR PKGBUILD.
#
# COPR builds this via the "rpkg" source method: it clones the repo and runs
# `rpkg srpm`, which expects this spec at the repository root.

Name:           grokbot-linux-port
Version:        0.43.0
Release:        1%{?dist}
Summary:        Grok Bot desktop agent (repacked from the official Linux .deb)

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

# Runtime libraries for Electron 42 (names translated from the official
# .deb's Depends list).
Requires:       alsa-lib
Requires:       at-spi2-core
Requires:       cairo
Requires:       expat
Requires:       gtk3
Requires:       hicolor-icon-theme
Requires:       libdrm
Requires:       libsecret
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
Grok Bot desktop agent for Linux, repacked verbatim from xAI's official
Linux .deb. The payload installs under /opt with its bundled Electron
runtime; this package adds the /usr integration (desktop entry, hicolor
icons, /usr/bin symlinks) that the .deb's own layout provides.

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
# The sha256 line re-verifies the bytes so a re-uploaded release asset
# fails the build instead of shipping changed bytes under the same NVR.
%ifarch aarch64
rm -rf %{payload_dir}
tar -xf %{SOURCE1}
echo "e78857471a1e3a09a370ee2378643e8b8de5c01e96cbb605348bc9186bae9e20  %{_sourcedir}/Grok_Bot_0.43.0_linux_arm64.tar.gz" | sha256sum -c -
cd %{payload_dir}
%else
rm -rf %{payload_dir}
tar -xf %{SOURCE0}
echo "b4b499ebd494cf5c4b98a12b7aee0ca6a8a1ced5ffabff4b612372f57a355870  %{_sourcedir}/Grok_Bot_0.43.0_linux_x64.tar.gz" | sha256sum -c -
cd %{payload_dir}
%endif

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
               %{buildroot}%{_licensedir}/%{name}

cp -a payload/. %{buildroot}/opt/%{name}/
chmod +x %{buildroot}/opt/%{name}/grok-bot

ln -s /opt/%{name}/grok-bot %{buildroot}%{_bindir}/grok-bot
ln -s /opt/%{name}/grok-bot %{buildroot}%{_bindir}/grokbot

cat > %{buildroot}%{_datadir}/applications/grok-bot.desktop <<'DESKTOP'
[Desktop Entry]
Name=Grok Bot
GenericName=Grok Bot
Comment=Grok Bot desktop agent
Exec=/opt/grokbot-linux-port/grok-bot %U
Icon=grok-bot
Type=Application
Categories=Utility;Development;
StartupWMClass=grok-bot
MimeType=x-scheme-handler/grokbot;x-scheme-handler/sand;
Terminal=false
DESKTOP

# The desktop entry anchors the -f filelist (a filelist must carry at least
# one entry); the icon lines join it below.
echo "%{_datadir}/applications/grok-bot.desktop" > "${builddir}/extra.filelist"

# The tarball ships the full hicolor tree (16..512) repacked from the .deb's
# /usr/share/icons, so the icon hunt/asar-extraction this spec used to carry
# is gone: copy the tree wholesale and list every size it contains. The
# tarball's hicolor/ IS the icons/hicolor subtree, hence the icons/ prefix
# added on install.
for png in hicolor/*/apps/grok-bot.png; do
  install -Dm644 "${png}" "%{buildroot}%{_datadir}/icons/${png}"
  echo "%{_datadir}/icons/${png}" >> "${builddir}/extra.filelist"
done
test -s "${builddir}/extra.filelist" \
  || { echo "error: tarball carries no hicolor icons" >&2; exit 1; }

# Upstream EULA lives inside app.asar; ship a pointer file as the license.
cat > "${builddir}/LICENSE" <<'LICENSE'
Grok Bot is proprietary software. This package repacks the official
Linux .deb published by xAI (resolved via downloads.cursor.com) into the
tarball at https://github.com/Nichokas/grokbot-linux-port/releases.
See upstream terms at https://grok.com and inside resources/app.asar.
LICENSE

# Chromium's user namespace sandbox needs setuid when kernel.unprivileged_
# userns_clone is off; the wrapper falls back to --no-sandbox otherwise.
# repack-deb.sh already bakes 4755 into the tarball; this guards a payload
# that arrives without it.
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
* Sat Sep 05 2026 Nichokas <nichokas@users.noreply.github.com> - 0.43.0-1
- Sync with upstream release v0.43.0 (x64 sha256 b4b499ebd494cf5c4b98a12b7aee0ca6a8a1ced5ffabff4b612372f57a355870) (arm64 sha256 e78857471a1e3a09a370ee2378643e8b8de5c01e96cbb605348bc9186bae9e20).

* Fri Sep 04 2026 Nichokas <nichokas@users.noreply.github.com> - 0.39.0-1
- Sync with upstream release v0.39.0 (x64 sha256 1a93eee1d5d39338ea24a94ae9fbcc2eccb6fa1183aaecfc49a0356f1c45ba58) (arm64 sha256 0dfbe36d2d9410b5e8db9ffc743431a1558eb63d6e488a955a5664416b2eee83).

* Thu Sep 03 2026 Nichokas <nichokas@users.noreply.github.com> - 0.36.0-1
- Sync with upstream release v0.36.0 (x64 sha256 8085c220956606639dd6b52e89f134418dd0d94d65c40f2a1663460a401d78a0) (arm64 sha256 27dce806e818ec74c3f0c874dd1c26dbe8ba14677a8d11dffd6f00121695dbd8).

* Mon Aug 31 2026 Nichokas <nichokas@users.noreply.github.com> - 0.30.0-3
- Pivot to repacking xAI's official Linux .deb (Electron 42 with native
  modules now ship for Linux): payload installs verbatim, icons come from
  the tarball's hicolor tree, desktop entry registers the sand:// handler.
  Release counter continues from the 0.30.0-2 already shipped so installed
  clients see the repacked bytes as an upgrade.

* Sun Aug 30 2026 Nichokas <nichokas@users.noreply.github.com> - 0.30.0-2
- Rebuild: bump the shared Release counter so the PPA re-upload lands as
  0.30.0~ppa2 after the dh_dwz/dh_shlibdeps build fix.

* Sat Aug 29 2026 Nichokas <nichokas@users.noreply.github.com> - 0.30.0-1
- Sync with upstream release v0.30.0 (x64 sha256 3623162e9442c504c43fb6df144e7aeecf9b5eb831040c70827adc98b5b49597) (arm64 sha256 67cb0332c40f5e3140f9f709c4c26065df00b9df5c4e53f15ad14aef44fafc9d).

* Thu Aug 27 2026 Nichokas <nichokas@users.noreply.github.com> - 0.29.0-1
- Sync with upstream release v0.29.0 (tarball sha256 0ed63f0beae1d5a61ec7b1ebb0d1d1931522c1c28ced0532c451cf4f294b3912).

* Wed Aug 26 2026 Nichokas <nichokas@users.noreply.github.com> - 0.27.0-1
- Sync with upstream release v0.27.0 (tarball sha256 4302bd55c2350c33c551e5877bdb7863b6bcfaf127ea79334ec0be242dcdbbf7).

* Tue Aug 25 2026 Nichokas <nichokas@users.noreply.github.com> - 0.25.0-2
- Extract grok-bot desktop icon from packed app.asar when no loose PNG is present.

* Tue Aug 25 2026 Nichokas <nichokas@users.noreply.github.com> - 0.25.0-1
- Initial Fedora/COPR packaging of the Grok Bot Linux port.
