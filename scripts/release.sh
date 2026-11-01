#!/bin/zsh
# Builds, signs and packages a release of Underbrim from a clean commit. Needs
# the keychain from scripts/make-signing-keychain.sh; macOS asks for your login
# password once, to let it unlock. Extra arguments go to xcodebuild. Set the
# project's MARKETING_VERSION (what people see) and CURRENT_PROJECT_VERSION (a
# whole number, one above the last release's) first.
#
# Writes build/release/Underbrim-<version>.zip and .dmg. Publishing stays
# manual: a GitHub release tagged v<version> with both files. It also writes
# Underbrim-<version>-dSYMs.zip, the symbols for this build's crash reports:
# keep it (a rebuild doesn't match), but it isn't for users.
set -euo pipefail
cd "${0:A:h}/.."
KC=~/Library/Keychains/underbrim-signing.keychain-db
IDENTITY="Underbrim Code Signing"
DERIVED=$PWD/build/DerivedData.noindex  # .noindex: Spotlight leaves the build out
OUT=$PWD/build/release
# The project builds in every file in its folders, committed or not.
if [[ -n $(git status --porcelain) ]]; then
  echo "Commit or remove these first, so the release matches a commit:" >&2
  git status --short >&2
  exit 1
fi

# A fresh app bundle: an earlier build leaves the folders of languages since
# removed in it, and macOS would then offer them (compiled code is kept).
rm -rf "$DERIVED/Build/Products"
# Xcode builds every file in the source folders, ignored ones too (not .DS_Store).
SOURCES=(Underbrim UnderbrimHelper Libraries)
LEFTOVERS=$(git status --porcelain --ignored -- $SOURCES)
LEFTOVERS=$(print -r -- "$LEFTOVERS" | grep -v '\.DS_Store$' || true)
if [[ -n $LEFTOVERS ]]; then
  echo "Remove these first; they would end up in the app:" >&2
  print -r -- "$LEFTOVERS" >&2
  exit 1
fi
# Built with an ad hoc signature, then signed below: Xcode won't sign with a
# certificate macOS doesn't trust, codesign will.
xcodebuild -project Underbrim.xcodeproj -scheme Underbrim -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' -quiet \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO "$@" build
APP=$DERIVED/Build/Products/Release/Underbrim.app
# What ships has no coverage counters (they'd write files wherever the relay
# runs) and no path from this Mac: the targets strip their Release builds
# (DEPLOYMENT_POSTPROCESSING), after the symbols are saved.
for exe in Contents/MacOS/Underbrim Contents/XPCServices/UnderbrimHelper.xpc/Contents/MacOS/UnderbrimHelper \
    Contents/Helpers/underbrim-relay; do
  [[ -f $APP/$exe ]] || { echo "$exe is missing" >&2; exit 1; }
  # grep reads all of otool's output: with -q it would stop early, and pipefail would hide the match.
  if otool -l "$APP/$exe" | grep __llvm_prf >/dev/null; then echo "$exe is built with coverage" >&2; exit 1; fi
done
if LC_ALL=C grep -rqa "$HOME" "$APP"; then
  echo "These files contain $HOME:" >&2
  LC_ALL=C grep -rla "$HOME" "$APP" >&2
  exit 1
fi
VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
BUILD=$(defaults read "$APP/Contents/Info" CFBundleVersion)
if [[ $BUILD != <-> ]]; then
  echo "CURRENT_PROJECT_VERSION must be a whole number (it's $BUILD)" >&2
  exit 1
fi

# Unlocked only while signing. Secrets go through security's stdin (print is
# a shell builtin), never a process's arguments.
trap 'security lock-keychain "$KC"' EXIT
print -r -- "unlock-keychain -p $(security find-generic-password -s underbrim-signing-keychain -w) $KC" \
  | security -i >/dev/null

# The licences travel inside the app (the zip has nothing else).
cp LICENSE NOTICE docs/THIRD_PARTY_LICENSES "$APP/Contents/Resources/"
scripts/sign-app.sh "$APP" "$KC" "$IDENTITY"
security lock-keychain "$KC"

rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Underbrim-$VERSION.zip"
# Underbrim isn't notarized: the image's background says how to get past
# Gatekeeper the first time.
scripts/make-dmg.sh "$APP" "$OUT/Underbrim-$VERSION.dmg"
( cd "$DERIVED/Build/Products/Release" && zip -qry "$OUT/Underbrim-$VERSION-dSYMs.zip" ./*.dSYM )

echo "Underbrim $VERSION, $(git rev-parse --short HEAD)"
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority|Identifier)="
( cd "$OUT" && shasum -a 256 *.zip *.dmg )
