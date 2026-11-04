---
name: terminal-googlebook
description: Operate a separate virtual Googlebook (Googlebook OS, Android 17) with screenshots, clicks, typing and Chrome, without touching the user's own desktop. Use when a task needs a real Googlebook or Chrome on Android, or any computer-use task the user wants kept off their Mac.
---

# terminal-googlebook

`terminal-googlebook` runs Google's Googlebook OS in a VM on Apple silicon. Screenshots and input go through the VM, so everything you do happens in the guest. It never controls the user's own desktop.

## Prefer the MCP tools

If tools named `start`, `screenshot`, `click`, `move`, `drag`, `scroll`, `type`, `key`, `home`, `back`, `recents`, `open_url` and `status` from the `terminal-googlebook` MCP server are available, use them in an observe → act → verify loop:

1. `start`: turns on the VM, or does nothing if it is on. Tell the user the command it returns, so they can watch you live. If it says the VM is not set up, ask the user to run the command it gives: the first time downloads about 9 GB.
2. If `userPicker` is `true`, take a `screenshot` and `click` **User**. There is no password.
3. For any web task, start with `open_url`. It opens a new Chrome tab and saves many clicks.
4. `screenshot`: every x/y you pass to other tools is a pixel in this image (top-left origin).
5. Act with `click` (`clicks: 2` double-clicks, `button: "right"`), `type` (literal text) or `key` (`enter`, `esc`, `tab`, `ctrl+t`, `ctrl+l`, arrows, `meta` opens the launcher, `alt+tab` switches windows), `scroll` (at `x`,`y`; negative `dy` scrolls down), `drag` (`x`,`y` to `toX`,`toY`), `move` (hover), and `home`, `back`, `recents` (Android's system buttons).
6. Look again: pass `screenshot: true` to an action, or call `screenshot`. A tool reporting "Sent" only means the input was delivered, so confirm the effect before the next step.

Click a field before typing into it, and give a just-opened window a moment to take focus: keys sent too early can be lost or reordered.

## First run of Chrome

On a new VM, the first `open_url` stops at Chrome's setup screens instead of the page:

- "Make Chrome your own": click **Stay signed out**, never **Add account to device**. This screen says that continuing accepts Chrome's terms and sends usage data to Google, so tell the user you passed it.
- "Chrome notifications make things easier": click **No thanks**.

Then call `open_url` again.

## Without MCP: the CLI

Every command prints JSON and exits nonzero on failure. `NAME` defaults to `default`.

```bash
terminal-googlebook status NAME                 # stopped → terminal-googlebook start NAME
terminal-googlebook action NAME screenshot --output /tmp/guest.png   # then view the PNG
terminal-googlebook action NAME click X Y [--button right] [--count 2]
terminal-googlebook action NAME move X Y
terminal-googlebook action NAME drag X Y TO_X TO_Y
terminal-googlebook action NAME scroll X Y --dy -300   # negative dy scrolls down
terminal-googlebook action NAME home                   # or back, recents
terminal-googlebook action NAME type 'literal text'
terminal-googlebook action NAME key ctrl+t
terminal-googlebook action NAME open_url https://example.com
```

## When to stop and ask the user

- A task needs a Google account, Google Play, a password, a two-factor code or a payment. This VM has no secure hardware and is a test device: do not put accounts or sensitive data in it.
- The VM does not exist: `terminal-googlebook up NAME` downloads about 9 GB from Google the first time.

## Safety

- Never fall back to host screenshots or host input tools.
- The guest has internet and can reach services on the host and the LAN through NAT. It is not hardened for hostile code.
- `stop` shuts Android down cleanly; `stop --force` can lose guest work, so use it only when a normal shutdown cannot complete.
