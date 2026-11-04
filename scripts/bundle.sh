#!/bin/sh
# release ビルドを dist/Amanuensis.app にまとめ、アドホック署名する。
# 第 1 引数でバージョン(`v1.2.3` か `1.2.3`)を受け取る。省略時は 0.0.0。
set -eu
cd "$(dirname "$0")/.."

# 不正な値ではビルドせず、既存の dist を残して終わる。
arg=${1-}
version=${arg:-0.0.0}
version=${version#v}
case $version in
  *[!0-9.]* | '') false ;;
  *) expr "$version" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null ;;
esac || {
  printf 'bundle.sh: バージョンは X.Y.Z か vX.Y.Z で指定する: %s\n' "$arg" >&2
  exit 1
}
echo "bundle.sh: version=$version"

swift build -c release
app=dist/Amanuensis.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Amanuensis" "$app/Contents/MacOS/Amanuensis"
# 動作確認用の音声と原稿(Resources/SelfCheck/sample.{wav,txt})をアプリに同梱する。
mkdir -p "$app/Contents/Resources"
cp -R Resources/SelfCheck "$app/Contents/Resources/SelfCheck"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>io.github.mosidas.amanuensis</string>
  <key>CFBundleName</key>
  <string>amanuensis</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$version</string>
  <key>CFBundleExecutable</key>
  <string>Amanuensis</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
