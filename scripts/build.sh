#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'terminal-googlebook requires Apple silicon.' >&2
  exit 1
fi
configuration="${CONFIGURATION:-release}"
identity="${SIGN_IDENTITY:--}"
echo "Signing with: $identity"
version="${VERSION:-0.1.0}"
build_number="${BUILD_NUMBER:-1}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo 'VERSION must be x.y.z and BUILD_NUMBER a positive integer.' >&2
  exit 1
fi
# Only Apple-issued certificates get a secure timestamp; it is required for notarization.
case "$identity" in
  -) sign_options=(--timestamp=none) ;;
  'Developer ID Application: '*) sign_options=(--options runtime --timestamp) ;;
  *) sign_options=(--options runtime --timestamp=none) ;;
esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
build_options=(--disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/configuration" --security-path "$PWD/.build/security")
swift build "${build_options[@]}" -c "$configuration"
binary_dir="$(swift build "${build_options[@]}" -c "$configuration" --show-bin-path)"
app="$PWD/dist/TerminalGooglebook.app"
mkdir -p "$app/Contents/MacOS"
# Replace rather than overwrite: rewriting a running VM's executable in place can kill it.
rm -f "$app/Contents/MacOS/terminal-googlebook"
cp "$binary_dir/terminal-googlebook" "$app/Contents/MacOS/terminal-googlebook"
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Clear dict' "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string dev.terminal-googlebook.host' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string TerminalGooglebook' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string terminal-googlebook' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 26.0' "$plist"
# The agent skill ships inside the app so `terminal-googlebook skills get` always matches this build.
rm -rf "$app/Contents/Resources/skills"
mkdir -p "$app/Contents/Resources/skills"
cp -R skills/googlebook "$app/Contents/Resources/skills/"
codesign --force --sign "$identity" "${sign_options[@]}" "$app"
ln -sfn TerminalGooglebook.app/Contents/MacOS/terminal-googlebook dist/terminal-googlebook
codesign --verify --deep --strict "$app"
echo "Built: $PWD/dist/terminal-googlebook"
