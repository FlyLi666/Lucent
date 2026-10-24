# Contributing to Lucent

Thanks for helping! Bug reports, ideas and pull requests are all welcome. 中文 issue / PR 也完全没问题。

## Before you start

- For anything bigger than a small fix, please open an issue first so we can agree on the approach.
- Search existing issues to avoid duplicates.

## Building

Requirements: macOS 26+, Xcode 27 (or a toolchain with the macOS 26+ SDK).

```bash
./build.sh          # release build → build/Lucent.app
./build.sh install  # also copies to /Applications and launches
swift build         # debug build (enables the debug flags below)
```

Useful debug flags: `--snapshots <dir>` (render every screen to PNG), `--snapshots <dir> --hold N` (keep the overview window open to measure CPU), `--usage-dump [--cold]` (print a full AI usage refresh). See the README for details.

## Ground rules

These keep Lucent light and trustworthy. PRs that break them will be asked to change.

1. **Stay light.** No third-party dependencies. Measure CPU and memory before/after any change to sampling, charts or motion (`--hold` + `top -pid`), and include the numbers in the PR.
2. **Motion via Core Animation.** Continuous animation must run in Core Animation, not per-frame SwiftUI. Short SwiftUI transitions for UI switches go through `UIMotion`. All motion must stop when the window is hidden, in Low Power Mode, or with Reduce Motion.
3. **Never read Claude credentials.** No OAuth tokens, Keychain items or `.credentials.json` for Claude — reading `oauthAccount` display fields from `.claude.json` is the limit.
4. **Credentials stay local.** Tokens never go to logs, caches, `UserDefaults` or debug output. Network requests use the no-cache, no-cookie session and only the documented hosts (`cursor.com`, `api2.cursor.sh`).
5. **Read other apps' data read-only and incrementally.** Stream, cap each round, skip unchanged files.
6. **Credit ported code.** Mark adapted code with a comment naming the project and license, and add its license to `THIRD_PARTY_NOTICES.md`.

## Pull requests

- Keep each PR focused on one change; describe what and why.
- For UI changes, attach before/after screenshots (`--snapshots` makes this easy).
- Make sure `swift build` produces no warnings.
- Code comments may be in Chinese or English; user-facing strings are currently Chinese.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE) and that you follow our [Code of Conduct](CODE_OF_CONDUCT.md).
