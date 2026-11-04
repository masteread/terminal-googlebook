#!/bin/bash
# Arma el paquete del release con firma ad-hoc: sin identidad ni credenciales, cualquiera puede repetirlo.
# La integridad la da el SHA-256 que get.sh verifica.  VERSION=x.y.z BUILD_NUMBER=N bash scripts/release.sh
# Requiere una compilación completa en vm/work.
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION="${VERSION:-0.1.0}" BUILD_NUMBER="${BUILD_NUMBER:-1}"
repo="${GITHUB_REPO:-masteread/terminal-googlebook}"
export SIGN_IDENTITY=-
python_url='https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.13.18%2B20261026-aarch64-apple-darwin-install_only_stripped.tar.gz'
python_sha256='8392b6ea51d94391befb2c31ebe75463f045d0b69dfcf5e1bb3234e1f5fa3405'
PATH="/opt/homebrew/opt/python@3.13/libexec/bin:$PATH" bash scripts/build.sh

name="terminal-googlebook-$VERSION-$BUILD_NUMBER-macos-arm64"
output="$PWD/dist/releases/$name"
[[ ! -e "$output" ]] || { echo "Release already exists: $output. Increment BUILD_NUMBER; releases are immutable." >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/terminal-googlebook-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT
curl -fsSL "$python_url" -o "$work/python.tar.gz"
echo "$python_sha256  $work/python.tar.gz" | shasum -a 256 -c - >/dev/null
tar -xzf "$work/python.tar.gz" -C "$work"

payload="$work/$name"
mkdir -p "$payload/vm"
ditto dist/TerminalGooglebook.app "$payload/TerminalGooglebook.app"
/usr/bin/python3 scripts/package_vm.py vm/work "$work/python" "$payload/bundle"
for item in install.sh fetch.sh build-image.sh lib.sh image tools run; do cp -R "vm/$item" "$payload/vm/"; done
find "$payload/vm" -name __pycache__ -type d -prune -exec rm -rf {} +
cp scripts/install.sh LICENSE THIRD_PARTY.md "$payload/"
cat > "$payload/README.txt" <<'TEXT'
terminal-googlebook: a virtual Googlebook for AI agents

Install: bash install.sh
Run:     ~/.local/bin/terminal-googlebook up

No Xcode or Homebrew needed. The first `up` downloads about 9 GB from Google and UTM.
See THIRD_PARTY.md for the licenses of the included binaries.
TEXT

# package_vm.py cambia algunos binarios; se vuelven a firmar todos, y QEMU necesita el permiso del hipervisor.
find "$payload/bundle" -type f -print0 | while IFS= read -r -d '' file; do
  if [[ "$(file -b "$file")" = Mach-O* ]]; then
    codesign --force --sign - --entitlements vm/host/hypervisor.entitlements.plist "$file" 2>/dev/null
  fi
done
archive_dir="$output"; mkdir -p "$archive_dir"
archive="$archive_dir/$name.zip"
ditto -c -k --sequesterRsrc --keepParent "$payload" "$archive"
sha="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
echo "$sha  $name.zip" > "$archive.sha256"
sed -e "s|@REPO@|$repo|g" -e "s|@TAG@|v$VERSION-$BUILD_NUMBER|g" -e "s|@ARCHIVE@|$name.zip|g" \
    -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD_NUMBER|g" -e "s|@SHA256@|$sha|g" packaging/get.sh > "$output/get.sh"
! grep -q '@[A-Z_]*@' "$output/get.sh" || { echo 'Unfilled template placeholder.' >&2; exit 1; }

# GPL: las fuentes exactas de lo que se distribuye van en el mismo release.
fetch_source() { curl -fsSL "$1" -o "$output/$(basename "$1")"; echo "$2  $output/$(basename "$1")" | shasum -a 256 -c - >/dev/null; }
fetch_source https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/qemu-10.0.12-utm.tar.xz 7c9605290b34152debb842e965a55d2e4fbba4793e536ab677b4027e5dc0ba1a
fetch_source https://git.kernel.org/pub/scm/linux/kernel/git/xiang/erofs-utils.git/snapshot/erofs-utils-1.9.4.tar.gz 7d135aa2550326a5acf20f53c518aea5a8900015ce50700044e40f818c31dd80
fetch_source https://downloads.sourceforge.net/project/e2fsprogs/e2fsprogs/v1.47.4/e2fsprogs-1.47.4.tar.gz 2cec05f39c20ee621f14926195664e66e6017190ac8e4bbdb16d86082e43c5da
fetch_source https://github.com/SELinuxProject/selinux/releases/download/3.11/libsepol-3.11.tar.gz 79f3d2c88f44b7eb5cf54d9792e03232297e17f97a179163f2750099a00f164d
fetch_source https://ftpmirror.gnu.org/gettext/gettext-1.0.tar.gz 85d99b79c981a404874c02e0342176cf75c7698e2b51fe41031cf6526d974f1a
echo "Publish every file in: $output"
