#!/bin/zsh
# Signs a built Underbrim.app with the release identity, from a keychain the
# caller has unlocked (see release.sh). Test builds are signed this way too, so
# they share the installed app's privacy permissions instead of replacing them:
# macOS keeps one grant per app id, for one signature.
# Usage: sign-app.sh <Underbrim.app> <keychain> <identity>
set -euo pipefail
APP=$1 KC=$2 IDENTITY=$3

# Every piece of code, innermost first: a bundle's main executable is signed
# as its bundle (.app, .xpc, .framework), anything else as itself.
typeset -aU targets
for file in ${(f)"$(find "$APP/Contents" -type f -perm -u+x)"}; do
  file -b "$file" | grep -q Mach-O || continue
  case $file in
    */Contents/MacOS/*) targets+=("${file%/Contents/MacOS/*}") ;;
    *.framework/Versions/*/*)
      framework=${file%/Versions/*}
      [[ ${file:t} == ${${framework:t}%.framework} ]] && targets+=("$framework") || targets+=("$file") ;;
    *) targets+=("$file") ;;
  esac
done
# The app loads its own frameworks, and self-signed code has no Team ID for
# library validation to match, so the app (only) may load them without one.
ENTITLEMENTS=$(mktemp)
codesign -d --entitlements - --xml "$APP" > "$ENTITLEMENTS"
# Set when the app was signed this way before (a build that left it as it was).
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :com.apple.security.cs.disable-library-validation true" "$ENTITLEMENTS"
for target in ${(f)"$(for t in $targets; do print -r -- "${#${t//[^\/]/}} $t"; done | sort -rn | cut -d' ' -f2-)"}; do
  if [[ $target == $APP ]]; then entitlements=(--entitlements "$ENTITLEMENTS")
  else entitlements=(--preserve-metadata=entitlements); fi
  codesign --force --timestamp=none --options runtime $entitlements --keychain "$KC" --sign "$IDENTITY" "$target"
done
rm -f "$ENTITLEMENTS"
codesign --verify --deep --strict "$APP"
