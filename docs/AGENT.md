# Using terminal-googlebook

`terminal-googlebook mcp [NAME]` is a stdio Model Context Protocol server with computer-use tools for the guest: `start`, `screenshot`, `click`, `move`, `drag`, `scroll`, `type`, `key`, `home`, `back`, `recents`, `open_url` and `status`. Coordinates are pixels in the latest `screenshot`. Action tools accept `screenshot: true` to return a fresh screenshot with the result.

```bash
claude mcp add terminal-googlebook -- /absolute/path/to/terminal-googlebook mcp
```

## First install

```bash
curl -fsSL https://github.com/masteread/terminal-googlebook/releases/latest/download/get.sh | bash
terminal-googlebook doctor   # JSON; exits nonzero if this Mac cannot run it
terminal-googlebook setup    # about 9 GB, usually 30 to 60 minutes: run it in the background
terminal-googlebook status   # progress while setup runs, as JSON
```

Without a terminal, `setup` prints one line per step and one every 30 seconds to stderr. If it stops, run it again: it continues where it left off. Only do this if the user agreed to the download.

The complete agent guide is the skill at [skills/terminal-googlebook/SKILL.md](../skills/terminal-googlebook/SKILL.md), which also ships inside the app (`terminal-googlebook skills get`).
