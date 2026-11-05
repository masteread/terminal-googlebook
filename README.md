# terminal-googlebook

Give your AI agent its own computer. terminal-googlebook runs Googlebook OS in a VM on your Apple silicon Mac, with no VM window and separate from your desktop. Agents control it through a CLI or MCP, and you watch them live in your terminal.

**Status:** early release, tested end to end on one Mac. See [Known limitations](#known-limitations).

## Quick start

You need Apple silicon, macOS 26 or later, 16 GB of RAM, 60 GB of free disk, and one of [iTerm2](https://iterm2.com), [Ghostty](https://ghostty.org) or [Kitty](https://sw.kovidgoyal.net/kitty/) to watch the VM. You don't need `sudo`, Xcode or Homebrew.

```bash
curl -fsSL https://github.com/masteread/terminal-googlebook/releases/latest/download/get.sh | bash
~/.local/bin/terminal-googlebook doctor    # checks this Mac
~/.local/bin/terminal-googlebook setup     # one time: about 9 GB, usually 30 to 60 minutes
```

The installer puts everything in `~/.local` and doesn't change your shell. The commands below assume `~/.local/bin` is on your `PATH`. If it isn't, add it:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

If `setup` stops, run it again: it continues where it left off.

Use `curl` to install. The package is ad-hoc signed and not notarized, so macOS rejects it if you download it with a browser. `get.sh` verifies its SHA-256.

## Give it to Claude Code

```bash
terminal-googlebook connect
```

Then, in any new Claude Code conversation, say "open your computer" in any language, or use the slash command:

```
/googlebook Find tickets for a concert in Mexico City and tell me the prices. Stop before choosing seats, signing in or paying.
```

Claude can also choose the computer by itself for tasks that need clicking through a real website.

Claude turns the VM on and opens a terminal window so you can watch it live. You see the screen, the agent's pointer with a ring on each click, and its latest action in the footer. You can also use the VM yourself.

The first time:

- Without `/googlebook`, Claude Code asks for permission once. Choose not to be asked again.
- With iTerm2, macOS may ask for Automation permission.

While the skill is active, Claude clicks and types in the VM without asking each time. It never controls your Mac.

For other MCP clients and for agents installing this themselves, see [docs/AGENT.md](docs/AGENT.md).

## Use it yourself

```bash
terminal-googlebook up       # boots the VM and opens the viewer
terminal-googlebook view     # opens the viewer; waits if the VM is off
terminal-googlebook action open_url https://example.com
terminal-googlebook action screenshot --output /tmp/guest.png
terminal-googlebook stop     # shuts the VM down
```

`Ctrl+]` closes the viewer and leaves the VM running. Only one VM can run at a time on each Mac. Run `terminal-googlebook help` for every command.

## Safety

Don't use this VM for accounts or sensitive data:

- It has no secure hardware.
- It isn't hardened against hostile code.
- Unless you create it with `--offline`, it has internet access and can reach services on your Mac and your local network.

## Known limitations

- **Barely tested on other Macs:** the full flow has only been completed on one Mac. A second Mac installed the program but stopped at the disk check.
- **Chrome window can disappear:** in 2 of 3 agent runs, the Chrome window left the screen while Chrome stayed active in the dock. The cause is unknown.
- **Lost keystrokes:** typing right after opening a window can lose characters. Agents should click the field and check the result.
- **Long sessions:** an 8-hour stability test hasn't been completed.
- **Live window:** opening it automatically has only been tested in iTerm2, not Ghostty or Kitty. The viewer doesn't work in macOS Terminal or inside tmux.
- **Disk use:** one used test install reached 71 GB, more than the 60 GB the setup check asks for.

Bug reports and pull requests are welcome. The [PRD](docs/PRD.md), [validation notes](docs/VALIDATION.md) and [spikes](docs/SPIKES.md) are in Spanish.

## Build from source

You need Homebrew, the Android SDK and Xcode:

```bash
cd vm && ./install.sh && cd ..
bash scripts/build.sh
dist/terminal-googlebook up
```

`VERSION=x.y.z BUILD_NUMBER=N bash scripts/release.sh` builds the release package in `dist/releases/`.

## Credits

This project is built on two MIT projects:

- [terminal-mac](https://github.com/govijr/terminal-mac) by Govijr: the original project, which runs all of macOS in your terminal. The CLI, MCP server and viewer come from it.
- [gbos-vm](https://github.com/skylartaylor/gbos-vm) by Skylar Taylor: Googlebook OS in a VM on a Mac, with GPU acceleration and the pointer helper. `vm/` is gbos-vm.

## License

MIT, except `vm/patches/cocoaspice-viewer.patch` (Apache-2.0). The release package includes third-party binaries under other licenses, including GPL: see [THIRD_PARTY.md](THIRD_PARTY.md). Nothing from Google is redistributed: the image is downloaded and verified on your machine.
