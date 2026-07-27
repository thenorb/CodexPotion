# CodexPotion 🧪

A tiny native macOS menu-bar meter for your remaining Codex usage.

CodexPotion shows the exact remaining percentage beside a colored potion bottle.
The liquid level moves in 10% increments and changes color as your available usage
drops:

- **70–100%:** green
- **40–60%:** cyan
- **20–30%:** yellow
- **10%:** orange
- **0%:** red

## Requirements

- macOS 14 or later
- Xcode Command Line Tools
- ChatGPT desktop app or Codex CLI installed and signed in

## Install

```bash
git clone https://github.com/thenorb/CodexPotion.git
cd CodexPotion
./install.sh
```

The installer builds a release version, copies it to
`~/Applications/CodexPotion.app`, ad-hoc signs it locally, and opens it.

To update:

```bash
git pull
./install.sh
```

## Use

- The menu-bar percentage and potion refresh automatically every 5 minutes by
  default.
- Use the menu's **− / + interval controls** to choose 30 seconds; 1, 2, 3, 4,
  5, 10, 15, 20, 30, 45, or 60 minutes. Your selection is retained between
  launches.
- Select **Refresh Usage** for an immediate update.
- Select **Launch at Login** if you want to enable it. It is off by default.
- The menu shows each exposed usage window with its remaining percentage and
  exact reset time, including the short and weekly windows when available.

## Privacy and security

CodexPotion intentionally has a narrow data surface:

- It does **not** read `~/.codex/auth.json`.
- It does **not** read Codex prompts, conversations, session logs, or workspace files.
- It does **not** access Claude credentials or Anthropic services.
- It contains no analytics, telemetry, advertising, or third-party backend.
- It does not make direct authenticated web requests.

The app launches the locally installed official `codex app-server` process and
requests `account/rateLimits/read` over a local JSON-RPC stdio connection. Codex
itself handles its existing authentication and OpenAI service communication. The
app receives only the rate-limit snapshot needed to render the meter.

The last successful percentage and reset time are cached locally in the app's
standard macOS preferences so the menu-bar display does not disappear during a
temporary refresh failure.

## Build from source

There are no third-party package dependencies.

```bash
./build-app.sh
open dist/CodexPotion.app
```

Or compile the Swift package directly:

```bash
swift build -c release
```

## Uninstall

Quit CodexPotion and disable **Launch at Login** first if you enabled it, then:

```bash
rm -r ~/Applications/CodexPotion.app
```

## Attribution

CodexPotion is derived from
[Lyric-o/NotchUsage](https://github.com/Lyric-o/NotchUsage), originally released
under the MIT License. The original copyright and license notice are preserved.

This derivative removes the notch overlay, Claude integration, direct credential
access, private usage endpoints, and local Codex session-log scanning. It replaces
them with a Codex-only menu-bar interface using the official local app-server.

## License

[MIT](LICENSE)
