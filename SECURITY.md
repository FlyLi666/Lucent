# Security Policy

Lucent reads local usage logs and, for Cursor, handles login tokens (kept in memory, or in the macOS Keychain for accounts you choose to remember). Please treat anything that could expose those as a security issue.

## Reporting a vulnerability

Please **do not** open a public issue. Use GitHub's private reporting instead:
**Security → Report a vulnerability** on <https://github.com/FlyLi666/Lucent/security/advisories/new>.

Include what you found, how to reproduce it, and the impact. You can expect an initial reply within a week. Please give us a reasonable time to ship a fix before disclosing publicly.

## Scope

In scope: credential handling (Cursor tokens, Keychain items), unexpected network requests, data written outside `~/Library/Caches/local.lucent.monitor/`, and anything that reads Claude credentials (Lucent must never do this).

Out of scope: issues that require an already-compromised user account or physical access to an unlocked Mac.
