#!/bin/bash
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="/Users/alex/Applications/RepoWatch.app"
ICONSET="$DIR/AppIcon.iconset"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/scripts"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/Resources/scripts/"*.sh "$APP/Contents/Resources/scripts/"
chmod +x "$APP/Contents/Resources/scripts/"*.sh

# Icono: symbol de SF Symbols sobre fondo de color, generado con AppKit.
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swiftc -O "$DIR/gen_icon.swift" -o "$DIR/gen_icon"
"$DIR/gen_icon" "$ICONSET/master.png"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" "$ICONSET/master.png" --out "$ICONSET/$name.png" >/dev/null
done
rm "$ICONSET/master.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$DIR/gen_icon"

swiftc -O -parse-as-library "$DIR/main.swift" "$DIR/Config.swift" "$DIR/PreferencesView.swift" \
    -o "$APP/Contents/MacOS/RepoWatch"
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
