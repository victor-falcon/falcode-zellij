#!/usr/bin/env python3

import json
import os
import pathlib
import re
import subprocess


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_OPENCODE_PLUGIN = REPO_ROOT / "opencode-plugin" / "falcode.js"
SOURCE_DETECTION_SCRIPT = REPO_ROOT / "scripts" / "detect-active-opencode.sh"
OPENCODE_DIR = pathlib.Path.home() / ".config" / "opencode"
OPENCODE_PLUGINS_DIR = OPENCODE_DIR / "plugins"
TARGET_OPENCODE_PLUGIN = OPENCODE_PLUGINS_DIR / "falcode.js"
OPENCODE_CONFIG_FILE = OPENCODE_DIR / "config.json"
STATE_DIR = pathlib.Path.home() / ".local" / "state" / "falcode-zellij"
TARGET_DETECTION_SCRIPT = STATE_DIR / "detect-active-opencode.sh"

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
    ensure_symlink(SOURCE_DETECTION_SCRIPT, TARGET_DETECTION_SCRIPT)
    ensure_opencode_config()
    ensure_symlink(SOURCE_WASM, TARGET_WASM)
    print(f"Linked {TARGET_OPENCODE_PLUGIN} -> {SOURCE_OPENCODE_PLUGIN}")
    print(f"Linked {TARGET_DETECTION_SCRIPT} -> {SOURCE_DETECTION_SCRIPT}")
    print(f"Updated {OPENCODE_CONFIG_FILE}")
    print(f"Linked {TARGET_WASM} -> {SOURCE_WASM}")
    print("If needed, reload Zellij so it picks up the latest plugin build.")


if __name__ == "__main__":
    main()
