#!/usr/bin/env python3

import json
import os
import pathlib
import re
import subprocess


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_OPENCODE_PLUGIN = REPO_ROOT / "opencode-plugin" / "falcode.js"
SOURCE_PI_EXTENSION = REPO_ROOT / "pi-extension" / "falcode.ts"
SOURCE_CLAUDE_HOOK = REPO_ROOT / "claude-extension" / "falcode-hook.sh"
SOURCE_DETECTION_SCRIPT = REPO_ROOT / "scripts" / "detect-active-opencode.sh"
SOURCE_NOTIFY_SCRIPT = REPO_ROOT / "scripts" / "oc-notify.sh"
OPENCODE_DIR = pathlib.Path.home() / ".config" / "opencode"
OPENCODE_PLUGINS_DIR = OPENCODE_DIR / "plugins"
TARGET_OPENCODE_PLUGIN = OPENCODE_PLUGINS_DIR / "falcode.js"
OPENCODE_CONFIG_FILE = OPENCODE_DIR / "config.json"
PI_EXTENSIONS_DIR = pathlib.Path.home() / ".pi" / "agent" / "extensions"
TARGET_PI_EXTENSION = PI_EXTENSIONS_DIR / "falcode.ts"
CLAUDE_DIR = pathlib.Path.home() / ".claude"
CLAUDE_SETTINGS_FILE = CLAUDE_DIR / "settings.json"
STATE_DIR = pathlib.Path.home() / ".local" / "state" / "falcode-zellij"
TARGET_DETECTION_SCRIPT = STATE_DIR / "detect-active-opencode.sh"
TARGET_NOTIFY_SCRIPT = STATE_DIR / "oc-notify.sh"
TARGET_CLAUDE_HOOK = STATE_DIR / "falcode-hook.sh"

CLAUDE_HOOK_EVENTS = (
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Notification",
    "Stop",
    "SessionEnd",
)

ZELLIJ_PLUGINS_DIR = pathlib.Path.home() / ".config" / "zellij" / "plugins"
SOURCE_WASM = REPO_ROOT / "target" / "wasm32-wasip1" / "release" / "falcode-zellij-sessions.wasm"
TARGET_WASM = ZELLIJ_PLUGINS_DIR / "falcode-opencode-sessions.wasm"


def load_jsonc(path: pathlib.Path) -> dict:
    raw = path.read_text(encoding="utf-8")
    raw = re.sub(r",(\s*[}\]])", r"\1", raw)
    return json.loads(raw)


def ensure_opencode_config() -> None:
    config = {}
    if OPENCODE_CONFIG_FILE.exists():
        config = load_jsonc(OPENCODE_CONFIG_FILE)
    plugins = config.get("plugin", [])
    if not isinstance(plugins, list):
        plugins = []
    plugin_ref = "./plugins/falcode.js"
    if plugin_ref not in plugins:
        plugins.append(plugin_ref)
    config["plugin"] = plugins
    if "$schema" not in config:
        config["$schema"] = "https://opencode.ai/config.json"
    OPENCODE_CONFIG_FILE.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


def _is_falcode_hook_entry(entry, cmd_prefix: str) -> bool:
    if not isinstance(entry, dict):
        return False
    inner = entry.get("hooks")
    if not isinstance(inner, list):
        return False
    for hook in inner:
        if not isinstance(hook, dict):
            continue
        cmd = hook.get("command", "")
        if isinstance(cmd, str) and cmd.startswith(cmd_prefix):
            return True
    return False


def ensure_claude_settings() -> None:
    settings = {}
    if CLAUDE_SETTINGS_FILE.exists():
        settings = load_jsonc(CLAUDE_SETTINGS_FILE)
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    cmd_path = str(TARGET_CLAUDE_HOOK)
    cmd_prefix = f"{cmd_path} "

    # Prune any falcode entries for events no longer in CLAUDE_HOOK_EVENTS
    # (e.g. SubagentStop, which we used to register and now must remove).
    for event in list(hooks.keys()):
        if event in CLAUDE_HOOK_EVENTS:
            continue
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue
        kept = [e for e in entries if not _is_falcode_hook_entry(e, cmd_prefix)]
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]

    for event in CLAUDE_HOOK_EVENTS:
        desired_cmd = f"{cmd_path} {event}"
        entries = hooks.get(event)
        if not isinstance(entries, list):
            entries = []
        already = False
        for entry in entries:
            inner = (entry or {}).get("hooks") if isinstance(entry, dict) else None
            if not isinstance(inner, list):
                continue
            for hook in inner:
                if isinstance(hook, dict) and hook.get("command") == desired_cmd:
                    already = True
                    break
            if already:
                break
        if not already:
            entries.append({"hooks": [{"type": "command", "command": desired_cmd}]})
        hooks[event] = entries
    settings["hooks"] = hooks
    CLAUDE_DIR.mkdir(parents=True, exist_ok=True)
    CLAUDE_SETTINGS_FILE.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")


def ensure_symlink(source: pathlib.Path, target: pathlib.Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_symlink() or target.exists():
        if target.is_symlink() and pathlib.Path(os.readlink(target)).resolve() == source.resolve():
            return
        target.unlink()
    target.symlink_to(source)


def build_wasm() -> None:
    subprocess.run(
        ["cargo", "build", "--release", "--target", "wasm32-wasip1"],
        cwd=REPO_ROOT,
        check=True,
    )


def main() -> None:
    build_wasm()
    ensure_symlink(SOURCE_OPENCODE_PLUGIN, TARGET_OPENCODE_PLUGIN)
    ensure_symlink(SOURCE_PI_EXTENSION, TARGET_PI_EXTENSION)
    ensure_symlink(SOURCE_CLAUDE_HOOK, TARGET_CLAUDE_HOOK)
    ensure_symlink(SOURCE_DETECTION_SCRIPT, TARGET_DETECTION_SCRIPT)
    ensure_symlink(SOURCE_NOTIFY_SCRIPT, TARGET_NOTIFY_SCRIPT)
    ensure_opencode_config()
    ensure_claude_settings()
    ensure_symlink(SOURCE_WASM, TARGET_WASM)
    print(f"Linked {TARGET_OPENCODE_PLUGIN} -> {SOURCE_OPENCODE_PLUGIN}")
    print(f"Linked {TARGET_PI_EXTENSION} -> {SOURCE_PI_EXTENSION}")
    print(f"Linked {TARGET_CLAUDE_HOOK} -> {SOURCE_CLAUDE_HOOK}")
    print(f"Linked {TARGET_DETECTION_SCRIPT} -> {SOURCE_DETECTION_SCRIPT}")
    print(f"Linked {TARGET_NOTIFY_SCRIPT} -> {SOURCE_NOTIFY_SCRIPT}")
    print(f"Updated {OPENCODE_CONFIG_FILE}")
    print(f"Updated {CLAUDE_SETTINGS_FILE}")
    print(f"Linked {TARGET_WASM} -> {SOURCE_WASM}")
    print("If needed, reload Zellij so it picks up the latest plugin build.")


if __name__ == "__main__":
    main()
