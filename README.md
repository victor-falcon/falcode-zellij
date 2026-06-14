# falcode-zellij

A Zellij plugin that shows all active AI agent panes across your Zellij sessions in a floating popup. It currently supports [OpenCode](https://opencode.ai), [pi](https://pi.dev), [oh-my-pi](https://github.com/can1357/oh-my-pi) (omp), and [Claude Code](https://docs.claude.com/en/docs/claude-code). Jump to any agent pane with a single keystroke, get macOS click-to-focus notifications when an agent finishes or needs your input, and see attention icons on your Zellij tabs.

![falcode-zellij screenshot](assets/screenshot.png)

> This plugins works really good with the [https://github.com/victor-falcon/git-worktree-zellij](git-worktree-zellij). Create and delete worktrees with a really simple cli.

## Installation

The plugin has two parts:

1. **Zellij WASM plugin** - the floating popup UI
2. **A session reporter** - the OpenCode plugin, pi extension, oh-my-pi extension, and/or the Claude Code hook, which report each pane's status and install the editable detection script in the shared state directory

### 1. Download the Zellij plugin

Download `falcode-zellij-sessions.wasm` from the [latest release](https://github.com/victor-falcon/falcode-zellij/releases/latest) and place it in your Zellij plugins directory:

```bash
mkdir -p ~/.config/zellij/plugins
curl -L https://github.com/victor-falcon/falcode-zellij/releases/latest/download/falcode-zellij-sessions.wasm \
  -o ~/.config/zellij/plugins/falcode-zellij-sessions.wasm
```

### 2a. Install the OpenCode plugin

Copy `falcode.js` to your OpenCode plugins directory:

```bash
mkdir -p ~/.config/opencode/plugins
curl -L https://raw.githubusercontent.com/victor-falcon/falcode-zellij/main/opencode-plugin/falcode.js \
  -o ~/.config/opencode/plugins/falcode.js
```

Then register it in `~/.config/opencode/config.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    "./plugins/falcode.js"
  ]
}
```

If you already have a `config.json`, just add `"./plugins/falcode.js"` to the existing `plugin` array.

### 2b. Install the pi extension

Copy `falcode.ts` to your pi extensions directory:

```bash
mkdir -p ~/.pi/agent/extensions
curl -L https://raw.githubusercontent.com/victor-falcon/falcode-zellij/main/pi-extension/falcode.ts \
  -o ~/.pi/agent/extensions/falcode.ts
```

Then restart pi or run `/reload` inside pi.

### 2c. Install the Claude Code hook

Claude Code uses hooks instead of a runtime plugin. Copy the hook script into the shared state directory and register it in your Claude Code settings.

```bash
mkdir -p ~/.local/state/falcode-zellij
curl -L https://raw.githubusercontent.com/victor-falcon/falcode-zellij/main/claude-extension/falcode-hook.sh \
  -o ~/.local/state/falcode-zellij/falcode-hook.sh
chmod +x ~/.local/state/falcode-zellij/falcode-hook.sh
```

Then add the following block to `~/.claude/settings.json` (merge with any existing `hooks` you have):

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "/Users/__YOUR_HOME__/.local/state/falcode-zellij/falcode-hook.sh SessionStart" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/Users/__YOUR_HOME__/.local/state/falcode-zellij/falcode-hook.sh UserPromptSubmit" }] }],
    "PreToolUse":       [{ "hooks": [{ "type": "command", "command": "/Users/__YOUR_HOME__/.local/state/falcode-zellij/falcode-hook.sh PreToolUse" }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "/Users/__YOUR_HOME__/.local/state/falcode-zellij/falcode-hook.sh PostToolUse" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "/Users/__YOUR_HOME__/.local/state/falcode-zellij/falcode-hook.sh Notification" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "/Users/__YOUR_HOME__/.local/state/falcode-zellij/falcode-hook.sh Stop" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "/Users/__YOUR_HOME__/.local/state/falcode-zellij/falcode-hook.sh SessionEnd" }] }]
  }
}
```

Replace `__YOUR_HOME__` with your actual home directory (Claude Code does not expand `~` inside hook commands).

The hook reads `ZELLIJ_PANE_ID` / `ZELLIJ_SESSION_NAME` from the environment, so panes opened outside Zellij are a no-op. Status transitions are surfaced as macOS notifications and `zellij-attention` pipes just like the OpenCode and pi integrations.

The hook is smart about *which* events deserve your attention:

- **Permission vs question** — Claude's `Notification` events are classified by their `notification_type`: `permission_prompt` (a tool needs approval) and `elicitation_dialog` (an MCP server wants input) raise distinct notifications; informational flavors (`idle_prompt`, `auth_success`, elicitation follow-ups) are silently ignored.
- **No spurious "ready" pings** — Claude fires `Stop` at the end of every assistant turn, even when the session is only paused waiting for background tasks or a scheduled wakeup (`run_in_background`, crons, `/loop`). The hook checks the `background_tasks` / `session_crons` payload arrays and suppresses the idle notification until the agent has truly finished.
- **Conversation titles** — notifications show Claude's generated conversation title (read live from the transcript), so you know *which* conversation needs you, not just which folder.

Set `FALCODE_CLAUDE_HOOK_DEBUG=1` to log raw hook payloads to `~/.local/state/falcode-zellij/claude-hook.log` (auto-truncated at ~256 KiB).

### 2d. Install the oh-my-pi extension

Copy `falcode.ts` to your oh-my-pi extensions directory:

```bash
mkdir -p ~/.omp/agent/extensions
curl -L https://raw.githubusercontent.com/victor-falcon/falcode-zellij/main/omp-extension/falcode.ts \
  -o ~/.omp/agent/extensions/falcode.ts
```

Then restart oh-my-pi or run `/reload` inside oh-my-pi.

### 2e. Install the notification helper script


If you want macOS click-to-focus notifications, also install the helper script into the shared state directory:

> **Note:** The notification click handler requires **Ghostty** as your terminal. Other terminals (Alacritty, iTerm2, etc.) do not support the AppleScript activation used to focus the terminal window on click.

```bash
mkdir -p ~/.local/state/falcode-zellij
curl -L https://raw.githubusercontent.com/victor-falcon/falcode-zellij/main/scripts/oc-notify.sh \
  -o ~/.local/state/falcode-zellij/oc-notify.sh
chmod +x ~/.local/state/falcode-zellij/oc-notify.sh
```

Notifications carry a status icon and the pane's live conversation title, with the folder and Zellij session as context:

| Status | Icon | Sound | Meaning |
|---|---|---|---|
| `idle` | ✅ | Glass | Agent finished — ready for you |
| `permission` | 🔐 | Funk | A tool needs your approval |
| `question` | ❓ | Ping | The agent is asking you something |

If the pane has been renamed to a conversation title (Claude reads it from the transcript; OpenCode/pi from the detection snapshot), the notification headline shows that title — otherwise it falls back to the folder name. Clicking the notification focuses the originating pane, switching Zellij session if needed.

## Configuration

Add a keybinding to your Zellij config (`~/.config/zellij/config.kdl`) to launch the plugin as a floating pane:

```kdl
keybinds {
    shared {
        bind "Alt o" {
            LaunchOrFocusPlugin "file:~/.config/zellij/plugins/falcode-zellij-sessions.wasm" {
                floating true
                state_dir "__YOUR_HOME_DIR__/.local/state/falcode-zellij"
            }
        }
    }
}
```

> **Note:** Zellij does not expand `~` or `$HOME` in plugin config values. Replace `__YOUR_HOME_DIR__` with your actual home directory (e.g. `/home/jane` on Linux, `/Users/jane` on macOS). You can get it by running `echo $HOME`.

The `state_dir` must match the directory where your reporter writes session state. The default is `~/.local/state/falcode-zellij`.

When the OpenCode plugin or pi extension starts, it also creates `detect-active-opencode.sh` and `detect-active-opencode.default.sh` inside that `state_dir`. The popup calls `detect-active-opencode.sh` to get the active pane list as JSON, so you can tweak detection logic there without rebuilding the WASM plugin.

- Edit `~/.local/state/falcode-zellij/detect-active-opencode.sh` to customize detection locally.
- `detect-active-opencode.default.sh` is the bundled reference copy that gets refreshed automatically.
- Your customized `detect-active-opencode.sh` is only created once and is not overwritten afterward.

### Configuration options

| Option | Description | Default |
|---|---|---|
| `state_dir` | Absolute path to the shared state directory | _(required)_ |
| `state_file` | Name of the legacy state file | `opencode-sessions.json` |

The popup now requests Zellij's `Run commands` permission as well, because it executes the detection shell script on the host.

### Notification debug logs

If a macOS notification click does not focus the expected pane/session, check:

- `~/.local/state/falcode-zellij/notification-clicks.log` — notification creation + click/focus attempts, including Ghostty activation details, primary/fallback zellij commands, session client snapshots before/after, and post-checks.
- `~/.local/state/falcode-zellij/terminal-notifier.log` — raw `terminal-notifier` output.
- `~/.local/state/falcode-zellij/claude-hook.log` — raw Claude Code hook payloads (opt-in via `FALCODE_CLAUDE_HOOK_DEBUG=1`).

## Tab attention icons (optional)

Integrates with [KiryuuLight/zellij-attention](https://github.com/KiryuuLight/zellij-attention) so the tab name gets an icon appended while an agent is working (⏳) and when it finishes (✅). Focusing the pane clears the icon automatically.

### 1. Install zellij-attention

```bash
mkdir -p ~/.config/zellij/plugins
curl -L https://github.com/KiryuuLight/zellij-attention/releases/latest/download/zellij-attention.wasm \
  -o ~/.config/zellij/plugins/zellij-attention.wasm
```

### 2. Load it from `~/.config/zellij/config.kdl`

```kdl
load_plugins {
    "file:~/.config/zellij/plugins/zellij-attention.wasm" {
        enabled "true"
        waiting_icon "⏳"     // shown while agent is working
        completed_icon "✅"   // shown when agent finishes
    }
}
```

Restart Zellij. Icons are configured here — change `waiting_icon` / `completed_icon` to any character or emoji.

### How it works

The OpenCode plugin / pi extension / Claude Code hook broadcasts a `zellij pipe --name "zellij-attention::<event>::<pane_id>"` on agent state transitions:

| Transition | Event sent | Default icon |
|---|---|---|
| idle → working / asking permission / question | `waiting` | ⏳ |
| working / asking permission / question → idle | `completed` | ✅ |
| Pane focused | _(cleared by zellij-attention)_ | — |

If zellij-attention isn't installed, the pipe is a harmless no-op.

### Environment overrides

| Variable | Effect |
|---|---|
| `FALCODE_DISABLE_ATTENTION=1` | Disable attention pipes entirely |
| `FALCODE_ATTENTION_ENTER_EVENT` | Event name on enter-active (default `waiting`) |
| `FALCODE_ATTENTION_EXIT_EVENT` | Event name on exit-active (default `completed`) |

## Usage

| Key | Action |
|---|---|
| `1`-`9` | Jump directly to the numbered pane |
| `j` / `Down` | Move selection down |
| `k` / `Up` | Move selection up |
| `Enter` | Focus the selected pane (switches session if needed) |
| `q` / `Esc` | Close the popup |

## Development

Build from source:

```bash
rustup target add wasm32-wasip1
cargo build --release --target wasm32-wasip1
```

The compiled plugin will be at `target/wasm32-wasip1/release/falcode-zellij-sessions.wasm`.

### Automated local install

For development, the install script builds the WASM plugin, symlinks the OpenCode plugin, the pi extension, the Claude Code hook, the detection script, and the notification helper into their expected locations, and registers the OpenCode plugin and the Claude Code hooks in their respective config files:

```bash
python3 scripts/install.py
```

## License

MIT
