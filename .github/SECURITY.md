# Security policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Use GitHub's private vulnerability reporting instead:
[Report a vulnerability](../../security/advisories/new)

Include a description of the issue, steps to reproduce, and the version of MockTab you tested against. You can expect an acknowledgment within a few days.

## Scope

MockTab runs without the macOS app sandbox (required for HID access and `CGEventPost`). This is a known limitation documented in `MockTab/MockTab.entitlements`. Vulnerabilities that require local code execution are generally out of scope; issues that allow privilege escalation or data exfiltration beyond what the unsandboxed process already permits are in scope.
