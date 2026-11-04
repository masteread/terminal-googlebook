# Using terminal-googlebook

`terminal-googlebook mcp [NAME]` is a stdio Model Context Protocol server with computer-use tools for the guest: `screenshot`, `click`, `type`, `key`, `open_url` and `status`. Coordinates are pixels in the latest `screenshot`. Action tools accept `screenshot: true` to return a fresh screenshot with the result.

```bash
claude mcp add terminal-googlebook -- /absolute/path/to/terminal-googlebook mcp
```

The complete agent guide is the skill at [skills/terminal-googlebook/SKILL.md](../skills/terminal-googlebook/SKILL.md), which also ships inside the app (`terminal-googlebook skills get`).
