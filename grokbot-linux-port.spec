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
Version:        0.25.0
Release:        1%{?dist}
Summary:        Grok Bot desktop — wine-less Linux port (prebuilt tarball)

# Upstream EULA lives inside resources/app.asar; see the installed LICENSE.
License:        Proprietary
URL:            https://github.com/Nichokas/grokbot-linux-port
Source0:        %{url}/releases/download/v%{version}/Grok_Bot_%{version}_linux_x64.tar.gz

# Prebuilt payload: nothing to strip, and the debuginfo machinery fails on
# the bundled Electron binaries.
%global debug_package %{nil}

# The tarball is produced by CI for linux-x64 only (see the build matrix in
# auto-update.yml) and carries x86_64 ELF binaries, so the RPM is
# arch-dependent on purpose: it must not be installable on other arches.
ExclusiveArch:  x86_64

BuildRequires:  coreutils
BuildRequires:  findutils
BuildRequires:  tar

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
%setup -q -n Grok_Bot_%{version}_linux_x64

# Belt and braces: the sha256 is also what Source0's URL pins, but a release
# re-upload (CI rebuilds non-deterministic bytes) must fail the RPM build
# loudly instead of shipping changed content under the same Version-Release.
echo "f4405f7ee46d91cc76e9b09bb3980673c7ddef01fb22b67f0c8007d02327fe85  %{_sourcedir}/Grok_Bot_%{version}_linux_x64.tar.gz" | sha256sum -c -

# The tarball keeps NSIS-derived restrictive modes (drwx------ on
# app.asar.unpacked); normalise so the installed tree is world-readable,
# matching the AUR package.
chmod -R u+rwX,go+rX,go-w .

%install
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
# a PNG is found (current tarballs embed it in app.asar, so the package
# ships without one, same as the AUR package). A -f filelist must contain at
# least one real entry, hence anchoring it on the desktop file.
echo "%{_datadir}/applications/grok-bot.desktop" > extra.filelist
icon=""
for cand in \
  resources/app.asar.unpacked/dist/renderer/assets/app-icon-*.png \
  resources/app.asar.unpacked/*.png \
  grok-bot.png
do
  [ -f "${cand}" ] && { icon="${cand}"; break; }
done
if [ -z "${icon}" ]; then
  icon="$(find . -name 'app-icon*.png' -print -quit || true)"
fi
if [ -n "${icon}" ] && [ -f "${icon}" ]; then
  install -m644 "${icon}" %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/grok-bot.png
  echo "%{_datadir}/icons/hicolor/256x256/apps/grok-bot.png" >> extra.filelist
fi

# Upstream EULA lives inside app.asar; ship a pointer file as the license.
cat > LICENSE <<'LICENSE'
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
* Tue Aug 25 2026 Nichokas <nichokas@users.noreply.github.com> - 0.25.0-1
- Sync with upstream release v0.25.0 (tarball sha256 f4405f7ee46d91cc76e9b09bb3980673c7ddef01fb22b67f0c8007d02327fe85).

* Fri Aug 21 2026 Nichokas <nichokas@users.noreply.github.com> - 0.24.0-1
- Sync with upstream release v0.24.0 (tarball sha256 f6b6495f9398a9d60702a282b404ac52e2b1c1c345d3ba81bbbd242e49ea6aad).

* Thu Aug 20 2026 Nichokas <nichokas@users.noreply.github.com> - 0.23.0-1
- Sync with upstream release v0.23.0 (tarball sha256 0cd3c9ac2f24e53cf021cfef4613db6902857262a918471033975d1ba5d7003c).

* Sun Aug 16 2026 Nichokas <nichokas@users.noreply.github.com> - 0.20.0-1
- Initial RPM packaging (prebuilt tarball variant, mirrors the AUR -bin package).
