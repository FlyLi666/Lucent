# Lucent

**English** · [简体中文](README.zh-CN.md)

A lightweight macOS menu bar monitor for temperature, CPU, memory and network — plus a usage dashboard for AI coding tools (Claude Code, Codex, OpenCode, Cursor). Native Swift, Liquid Glass UI, no third-party dependencies.

![Lucent](docs/design/shot-1.jpg)

## Features

- **Menu bar glyph** in three styles (tick ring / pulse line / dual orbit). Monochrome until the CPU passes your alert temperature. The text next to it can show temperature, CPU, memory, or nothing.
- **Card** (left click): temperature, CPU, memory and network with live "silk thread" charts, plus the top processes or AI usage. Each module can be hidden in Settings.
- **Main window** (⌥-click or ⌘O): overview, temperature sensors, per-core CPU, memory, network, AI usage, machine info, and a Settings page (⌘,).
- **AI usage** for Claude Code, Codex, OpenCode and Cursor: cost, requests, tokens, cache hit rate, trends, request log, per-model / per-project / per-provider breakdowns, a yearly heatmap, and a local estimate of the current 5-hour window with burn rate.
- **Multiple accounts**: Claude Code and Codex accounts are separated by config directory (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`); extra Cursor accounts can be remembered in the macOS Keychain. With a single account nothing about accounts is shown.
- **Personalization**: alert temperature, °C / °F, MB/s or Mbps, card modules, glyph style and text, motion on/off, native Liquid Glass or frosted material.

## Requirements

- macOS 26 or later (Apple Silicon recommended; Intel Macs are untested).
- Xcode 27 (or a toolchain with the macOS 26+ SDK) to build. Older Command Line Tools cannot parse the package manifest.

## Build & install

```bash
git clone https://github.com/FlyLi666/Lucent.git
cd Lucent
./build.sh install      # build → copy to /Applications → launch
```

`./build.sh` alone builds `build/Lucent.app`. If you have several Xcode versions, point the build at the right one first, e.g. `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The script signs the app with the first "Apple Development" certificate it finds, so Keychain permissions survive updates; without one it falls back to ad-hoc signing (you will be asked to allow Keychain access again after each update if you use remembered Cursor accounts).

## Usage

- **Left click** the menu bar glyph: open the card. Click elsewhere or press Esc to close.
- **Right click** (or Control-click): menu with refresh interval, glyph style and launch at login.
- **⌥-click**: open the main window directly. ⌘O from the card does the same; ⌘, opens Settings.

## AI usage: where the data comes from

| Tool | Source | Notes |
|---|---|---|
| Claude Code (CLI + desktop) | Local `~/.claude/projects/**/*.jsonl` (and any extra config directories you add) | Costs are API-equivalent prices from LiteLLM's price table, not your actual bill. **Lucent never reads Claude credentials** — third-party collection of session tokens is against Anthropic's terms — so official quotas are only reachable via the "Open usage page" button. |
| Codex (CLI + desktop) | Local `~/.codex/sessions` (or `$CODEX_HOME`) and `state_5.sqlite` for sessions whose logs were deleted | Costs are API-equivalent. Totals recovered from the database have no input/output split and no cost. |
| OpenCode | Local `~/.local/share/opencode/opencode.db`, read-only | Tokens and costs as recorded by OpenCode. |
| Cursor | The signed-in token from Cursor's local database → `cursor.com` usage APIs | The current login's token is kept in memory only. Remembered extra accounts are stored in the macOS Keychain. Requests go only to `cursor.com` (and `api2.cursor.sh` to refresh an expired token of a remembered, not-currently-signed-in account). No HTTP cache or cookies are written. |

Daily aggregates are cached in `~/Library/Caches/local.lucent.monitor/` (numbers, model names and the last path component of project directories — no conversation content, no credentials), so the heatmap keeps growing beyond the tools' own log retention.

## Why it stays light

| Approach | Effect |
|---|---|
| The menu bar glyph is a small image redrawn only when its content changes | No SwiftUI views run while only the glyph is visible |
| The card and the main window release their whole view tree when closed | Idle memory is just the sampler |
| One background timer (2 s by default, 20% leeway); sampling stops while displays sleep | Coalesced wake-ups, zero cost with the lid closed |
| Only mach / sysctl / IOKit calls — no `top` or `ps` | Microsecond-level samples |
| All motion runs in Core Animation (render server); the app commits new data about once per second | Measured ~0.3–0.7% CPU / 16 MB with only the glyph; ~6–8% with the main window and motion on |
| Motion stops when windows are hidden, in Low Power Mode, or with Reduce Motion | |
| AI logs are read incrementally as byte streams; unchanged files are skipped; huge lines are not parsed; each round is capped | A cold scan of ~1 GB of logs peaks around 170 MB and is spread over a few rounds |

## Notes

- Not sandboxed (reading SMC temperatures requires it), so it cannot ship on the Mac App Store.
- The first launch scans SMC keys once; later launches use the cached key list.
- Root-owned system processes are not visible in the process list without privileges.

## Development

Debug builds (`swift build`) accept a few flags:

- `--snapshots <dir>` renders the card, every main window section and the menu bar glyphs to PNG after ~20 s and exits. Add `-usageFixture YES` to fill AI views with sample data, `-usage.tab heatmap` etc. to pick a tab.
- `--snapshots <dir> --hold N` only opens the overview window for N seconds — handy for measuring CPU with `top -pid`.
- `--usage-dump [--cold]` prints one full usage refresh (never any credentials) and exits; `--cold` uses a fresh temporary cache.
- Any preference can be overridden for one run, e.g. `-ui.tempUnit f -card.showNet NO`.

The app icon is drawn by `scripts/make-icon.swift`; run `scripts/make-icon.sh` to regenerate `Resources/AppIcon.icns`.

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## License

[MIT](LICENSE). Lucent includes code and data adapted from AirStats, CodexBar, tokscale, ccusage, CC Switch and LiteLLM (all MIT), and bundles the Doto and JetBrains Mono fonts (SIL OFL 1.1). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
