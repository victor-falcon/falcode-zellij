# falcode-zellij

Zellij popup plugin for showing active OpenCode sessions.

## What it includes

- a Zellij WASM plugin built from `src/main.rs`
- a repo-owned OpenCode plugin in `opencode-plugin/falcode.js`
- a single installer script in `scripts/install.py`

## Local build

```bash
rustup target add wasm32-wasip1
cargo build --release --target wasm32-wasip1
```

## Install

```bash
python3 scripts/install.py
```
