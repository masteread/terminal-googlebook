#!/bin/bash
# Installs terminal-googlebook @VERSION@ (build @BUILD@):
#   curl -fsSL https://github.com/@REPO@/releases/latest/download/get.sh | bash
# Options pass through to install.sh, for example: | bash -s -- --prefix "$HOME/.local"
# Downloads one signed archive from GitHub, verifies its SHA-256, then installs it under
# ~/.local without administrator rights. VM data is never touched.
set -euo pipefail
archive='@ARCHIVE@'
url='https://github.com/@REPO@/releases/download/@TAG@/@ARCHIVE@'
sha256='@SHA256@'
[[ "$(uname -s)" = Darwin && "$(uname -m)" = arm64 ]] || { echo 'terminal-googlebook requires a Mac with Apple silicon.' >&2; exit 1; }
os_major="$(sw_vers -productVersion)"; os_major="${os_major%%.*}"
[[ "$os_major" -ge 26 ]] || { echo 'terminal-googlebook requires macOS 26 or later.' >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/terminal-googlebook-get.XXXXXX")"
trap 'rm -rf "$work"' EXIT
echo "Downloading terminal-googlebook @VERSION@…"
curl -fL --progress-bar "$url" -o "$work/$archive"
echo "$sha256  $work/$archive" | shasum -a 256 -c - >/dev/null || { echo 'Checksum mismatch; nothing was installed.' >&2; exit 1; }
ditto -x -k "$work/$archive" "$work/unpacked"
bash "$work/unpacked/${archive%.zip}/install.sh" "$@"
cat <<'TEXT'

Next:
  terminal-googlebook doctor                                      # check this Mac
  terminal-googlebook up                                          # first run downloads about 9 GB
  claude mcp add terminal-googlebook -- terminal-googlebook mcp   # computer-use tools for Claude Code
  terminal-googlebook skills install                              # the agent skill (~/.claude/skills)
  terminal-googlebook mcp --config                                # config for other MCP clients
TEXT
