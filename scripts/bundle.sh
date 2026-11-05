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
cp Resources/MenuBarIcon.pdf "$app/Contents/Resources/MenuBarIcon.pdf"
cp Resources/MenuBarIconRecording.tiff "$app/Contents/Resources/MenuBarIconRecording.tiff"

# Resources/AppIcon.png(1024 px)から 10 サイズの iconset を作り、AppIcon.icns に固める。
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
iconset=$tmp/AppIcon.iconset
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"

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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>会議の相手の声を録音するために使います。</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>会議の自分の声を録音するために使います。</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>録音を書類フォルダーの amanuensis に保存するために使います。</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
