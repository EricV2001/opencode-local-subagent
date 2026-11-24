# Changelog

## 0.2.0 (2026-11-24)

### Security
- Guard plugin that checks every shell command after unquoting, because OpenCode matches its permission
  patterns against the raw command text and quoting defeated them. The shell allowlists are much shorter.
- OS sandbox on Linux and WSL2 (bubblewrap), next to the existing macOS `sandbox-exec` layer. Reads are
  confined to the folder, the toolchain and OpenCode's own files; secrets (`.env`, keys, `~/.ssh`) are hidden.
- Platforms without a working sandbox refuse `build` runs unless you pass `--no-sandbox`.
- `--no-web` pins the network to LM Studio on macOS.
- A folder's own OpenCode config (`opencode.json`, `.opencode/` plugins) can no longer override the rules
  or run code (findings S21, S27).
- Worktree git hardened against a redirected `.git`. The report is hardened against spoofing, and the
  model's context length is validated before use.

### Added
- OpenCode 2.x support. Tested with 1.19.5, 1.19.6, 2.3.0 and 2.4.1.
- Auto-resume after an LM Link drop (`OCLS_AUTO_RESUME`), a stall timeout, and an optional SSH route
  (`--ssh <host>` / `OCLS_SSH_HOST`).
- `install.sh` checks whether bubblewrap works on Linux.

### Fixed
- Sessions resume in their own directory or worktree.
- No `__pycache__` files in build diffs.
- Many smaller fixes; see [docs/findings.md](docs/findings.md) for the measurements behind them.

## 0.1.0 (2026-11-03)

First version: LM Studio model auto-detection, the `explore`/`review`/`build` permission profiles,
worktree builds, compact reports, and packaging as a Claude Code plugin.
