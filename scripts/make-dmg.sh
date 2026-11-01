#!/bin/zsh
# Packages an app as Underbrim's disk image: the app and a link to Applications
# over the background in scripts/dmg. Finder lays the window out and keeps the
# layout in the image's .DS_Store, so the image's window opens on screen while
# this runs. Usage: make-dmg.sh <Underbrim.app> <out.dmg>
set -euo pipefail
APP=${1:A}; OUT=${2:A}
NAME=Underbrim
MNT=/Volumes/$NAME
# Finder finds the window by the volume's name, so it must be the only one.
[[ ! -e $MNT ]] || { echo "Eject $MNT first." >&2; exit 1; }

# Its own folder in /tmp: the layout records the path of the image it was made in.
WORK=$(mktemp -d /tmp/underbrim-dmg.XXXXXX)
trap '[[ -d $MNT ]] && hdiutil detach -quiet -force "$MNT"; rm -rf "$WORK"' EXIT
STAGE=$WORK/stage
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "${0:A:h}/dmg/background.tiff" "$STAGE/.background/"
hdiutil create -quiet -volname $NAME -fs HFS+ -srcfolder "$STAGE" -format UDRW "$WORK/$NAME.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen -mountpoint "$MNT" "$WORK/$NAME.dmg"

# The background is drawn for these positions (icon centres) and this icon size.
# The window shows 420 points of it below its 32-point title bar, or 384 when
# Finder shows its tab bar, so the first-open steps end above that; the
# background runs to 440, so a taller window leaves no gap.
osascript <<EOF
tell application "Finder"
  tell disk "$NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {300, 200, 960, 652}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$NAME.app" of container window to {170, 200}
    set position of item "Applications" of container window to {490, 200}
    close
    open
    delay 2
    close
  end tell
end tell
EOF
for _ in {1..20}; do [[ -f $MNT/.DS_Store ]] && break; sleep 0.5; done
[[ -f $MNT/.DS_Store ]] || { echo "Finder didn't save the layout." >&2; exit 1; }
# The volume's icon goes on after Finder is done with the window: refreshing it drops the icon.
cp "$APP/Contents/Resources/AppIcon.icns" "$MNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MNT"
rm -rf "$MNT/.fseventsd"
hdiutil detach -quiet "$MNT"
rm -f "$OUT"
hdiutil convert -quiet "$WORK/$NAME.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
