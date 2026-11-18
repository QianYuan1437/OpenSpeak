#!/bin/bash
# Packages build/linux/x64/release/bundle as a .tar.gz and a .deb into dist/.
set -euo pipefail
VERSION=${1:?version}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUNDLE=$ROOT/build/linux/x64/release/bundle
DIST=$ROOT/dist
mkdir -p "$DIST"

tar -C "$BUNDLE/.." -czf "$DIST/OpenSpeak-$VERSION-linux-x64.tar.gz" --transform "s|^bundle|OpenSpeak|" bundle

PKG=$(mktemp -d)/openspeak
mkdir -p "$PKG/DEBIAN" "$PKG/opt/openspeak" "$PKG/usr/bin" \
  "$PKG/usr/share/applications" "$PKG/usr/share/icons/hicolor/256x256/apps"
cp -r "$BUNDLE"/. "$PKG/opt/openspeak/"
ln -s /opt/openspeak/openspeak "$PKG/usr/bin/openspeak"
cp "$ROOT/linux/runner/openspeak.png" "$PKG/usr/share/icons/hicolor/256x256/apps/openspeak.png"
cat > "$PKG/usr/share/applications/openspeak.desktop" <<DESKTOP
[Desktop Entry]
Name=OpenSpeak
Comment=Offline voice typing / 离线语音输入
Exec=openspeak
Icon=openspeak
Terminal=false
Type=Application
Categories=Utility;Accessibility;
StartupWMClass=io.github.qianyuan1437.openspeak
DESKTOP
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: openspeak
Version: ${VERSION//-/\~}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: QianYuan1437 <zyh42018108@163.com>
Depends: libgtk-3-0, libayatana-appindicator3-1, pulseaudio-utils, xdotool
Homepage: https://github.com/QianYuan1437/OpenSpeak
Description: Offline cross-platform voice typing
 Hold a hotkey, speak, and OpenSpeak types the text into any app.
 Speech recognition runs locally with sherpa-onnx (SenseVoice and more).
CONTROL
dpkg-deb --build --root-owner-group "$PKG" "$DIST/OpenSpeak-$VERSION-linux-amd64.deb"
ls -la "$DIST"
