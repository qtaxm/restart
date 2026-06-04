# Custom Codex Config

macOS interactive one-command setup:

```bash
curl -fsSL https://raw.githubusercontent.com/qtaxm/restart/main/codex-custom.sh | bash
```

The script only writes Codex config files:

- `~/.codex/config.toml`
- `~/.codex/auth.json`

It does not install Node.js, npm, or Codex.

If you run it with `sudo bash`, it will still write to the original macOS user's `~/.codex` directory.

For an IP plus port, use `http://198.20.155.154:8808/v1`, not `http://198.20.155.154/:8808`.
