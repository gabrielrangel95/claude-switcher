# Claude Switcher

A macOS menu bar + notch app for switching Claude Code between several Claude accounts
(e.g. personal / job / company) in one click, with live 5-hour and weekly usage for each.

<p align="center">
  <img src="docs/demo.gif" alt="Hovering the notch shows each account's usage; clicking Work switches Claude Code to it, and claude-switch list confirms Work is active" width="880">
</p>

- **One-click switching** from the menu bar or the notch, no browser login after the first time
- **Live usage** for every account: 5-hour and weekly limits, with reset times
- **Notch panel** that shows the active account and expands on hover (falls back to a top-center pill on Macs without a notch)
- **CLI** (`claude-switch`) that shares the same saved accounts
- Tokens stay in the macOS Keychain. Nothing leaves your machine except calls to Anthropic's own API

## Build & run

```sh
git clone https://github.com/gabrielrangel95/claude-switcher.git
cd claude-switcher
make run        # builds build/Claude Switcher.app and opens it
make install    # copies it to /Applications and opens it
```

Requires macOS 14+ and Xcode / Swift 6. The app is ad-hoc signed by `scripts/bundle.sh`,
so it runs on the machine that built it without notarization.

## First-time setup (once per account)

1. Open the menu bar item (✳︎) → **Add account → Save current Claude Code login**.
2. **Add account → Log in to another account…** opens Terminal with `claude auth login`.
   Finish the browser login; the app detects it and saves the account automatically.
3. Repeat step 2 for each remaining account. Rename / recolor them in Settings.

After that, switching is one click in the menu or the notch panel. No more browser logins.

## Terminal

The app binary also works as a CLI (it shares the saved accounts with the app):

```sh
ln -s "/Applications/Claude Switcher.app/Contents/MacOS/ClaudeSwitcher" ~/.local/bin/claude-switch
claude-switch list        # accounts + usage
claude-switch work        # switch by label or email prefix
claude-switch save        # save the current login
```

## How switching works

Claude Code keeps its login in two places. A switch replaces exactly these two values and
nothing else:

| Where | What changes | Preserved |
|---|---|---|
| Keychain item `Claude Code-credentials` | `claudeAiOauth` (tokens) | `mcpOAuth` and any other keys |
| `~/.claude.json` | `oauthAccount` (identity) | everything else |

Before every switch the app re-reads the live login and stores its latest tokens, because
Claude Code rotates them on refresh. Saved logins live in Keychain items with service `ClaudeSwitcher`.
The previous `~/.claude.json` is saved as `~/.claude.json.switcher-bak` (Settings → Restore).

- A switch applies to **new** `claude` sessions. Restart sessions that are already running.
  A running session that later refreshes its token may write its old account back. The app
  notices within a few seconds and shows which account is really active.
- The app never refreshes the active account's token (Claude Code owns it). It refreshes
  inactive accounts' tokens only when they expire, to keep their usage current.
- Usage comes from `api.anthropic.com/api/oauth/usage`, the undocumented endpoint behind
  Claude Code's `/usage`. If it changes, usage shows as unavailable, but switching keeps working.

## Contributing

Issues and pull requests are welcome. The code is small: `Store/` reads and writes Claude
Code's login, `Service/` handles switching, usage and the CLI, and `UI/` is SwiftUI.

## Disclaimer

This is an independent project, not affiliated with or endorsed by Anthropic. It relies on
how Claude Code stores its login today, which may change in future versions.

## License

[MIT](LICENSE)
