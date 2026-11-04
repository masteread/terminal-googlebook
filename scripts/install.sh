#!/bin/bash
# Installs a prebuilt package. No compiler, administrator rights, or network needed.
set -euo pipefail
prefix="${TERMINAL_GOOGLEBOOK_PREFIX:-$HOME/.local}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) [[ $# -ge 2 ]] || { echo '--prefix requires a directory' >&2; exit 1; }; prefix="$2"; shift 2 ;;
    --help|-h) echo 'Usage: bash install.sh [--prefix DIRECTORY]'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ "$prefix" = /* ]] || { echo 'The install prefix must be an absolute path.' >&2; exit 1; }
[[ "$(uname -m)" = arm64 ]] || { echo 'terminal-googlebook requires Apple silicon.' >&2; exit 1; }
os_major="$(sw_vers -productVersion)"; os_major="${os_major%%.*}"
[[ "$os_major" -ge 26 ]] || { echo 'terminal-googlebook requires macOS 26 or later.' >&2; exit 1; }
source_dir="$(cd "$(dirname "$0")" && pwd)"
source_app="$source_dir/TerminalGooglebook.app"
[[ -d "$source_app" && -d "$source_dir/vm" && -d "$source_dir/bundle" ]] || { echo 'The package is incomplete. Extract the complete release package first.' >&2; exit 1; }
codesign --verify --deep --strict "$source_app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$source_app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid package version.' >&2; exit 1; }
digest="$(shasum -a 256 "$source_app/Contents/MacOS/terminal-googlebook")"; digest="${digest%% *}"; digest="${digest:0:12}"
library="$prefix/lib/terminal-googlebook"
destination="$library/$version-$build_number-$digest"
launcher="$prefix/bin/terminal-googlebook"
mkdir -p "$library" "$prefix/bin"
if ! mkdir "$library/.install-lock" 2>/dev/null; then echo 'Another installation is running. If it was interrupted, remove the .install-lock directory and retry.' >&2; exit 1; fi
staging=""
cleanup() { if [[ -n "$staging" && -d "$staging" ]]; then rm -rf "$staging"; fi; rmdir "$library/.install-lock"; }
trap cleanup EXIT
if [[ -e "$launcher" || -L "$launcher" ]]; then
  existing="$(readlink "$launcher" || true)"
  case "$existing" in "$library/"*/TerminalGooglebook.app/Contents/MacOS/terminal-googlebook) ;;
    *) echo "Refusing to replace an unrelated file: $launcher" >&2; exit 1 ;;
  esac
fi
if [[ ! -d "$destination" ]]; then
  staging="$(mktemp -d "$library/.install-XXXXXX")"
  ditto "$source_app" "$staging/TerminalGooglebook.app"
  ditto "$source_dir/vm" "$staging/vm"
  ditto "$source_dir/bundle" "$staging/bundle"
  codesign --verify --deep --strict "$staging/TerminalGooglebook.app"
  mv "$staging" "$destination"; staging=""
else
  codesign --verify --deep --strict "$destination/TerminalGooglebook.app"
fi
temporary_link="$prefix/bin/.terminal-googlebook-$$"
ln -s "$destination/TerminalGooglebook.app/Contents/MacOS/terminal-googlebook" "$temporary_link"
mv -f "$temporary_link" "$launcher"
echo "Installed terminal-googlebook $version: $launcher"
case ":$PATH:" in *":$prefix/bin:"*) echo 'Run: terminal-googlebook up' ;;
  *) echo "Add $prefix/bin to your PATH, or run:"; echo "  \"$launcher\"" ;;
esac
