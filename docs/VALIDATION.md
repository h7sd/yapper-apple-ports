# Recorded validation

Local checks dated **2026-10-30**. Results apply to the inspected client sources and listed builds, not to future revisions or all remote service behavior.

## macOS

- 17 Node regression/process-enumeration tests passed.
- Both Apple Silicon and Intel ZIPs passed 16 checks each, including packaged source identity, actual Electron 45.1.0 version, correct native-addon architecture, portable framework links, and strict nested ad-hoc code-signature verification.
- 10 live Apple Silicon app checks passed: anonymous login interface, renderer isolation/17-member bridge, settings, native app enumeration, unavailable-feature handling, Dock badge, native zoom commands, close/reopen, invite routing, and failure/Retry recovery.
- Full locked dependency audit: **0 known advisories** at the recorded time, after updating the vulnerable original runtime. This is a dependency-advisory result, not an antivirus or malware verdict.
- The Intel build was not run on an Intel Mac.

Machine-readable checks and scope are in [`reports/`](reports/). Build instructions and public GitHub Actions allow others to repeat the checks. ZIP timestamps/signatures may differ when rebuilt; no bit-for-bit reproducible-build claim is made.

## iOS

- 12 JavaScript bridge tests passed, including origins/ports, malformed inputs, native rejections, and unavailable desktop features.
- Release iOS Simulator application compiled for arm64/x86_64.
- Generic iPhone/iPad Release archive compiled for arm64 and packaged as an unsigned IPA without a provisioning profile.
- Swift unit/hosted WebKit and original-login UI checks passed on an iPhone 17 Pro simulator with iOS 26.4.1: **30 passing case executions across 8 test functions**, no failures/skips/runtime warnings. This includes a real WKWebView-to-native settings roundtrip and truthful refusals for badges without consent and unsupported hotkeys.
- The iOS 27.2 simulator initially stalled before test launch. That attempt was not counted as a pass; the same app sources were verified on the stable runtime instead.

## GitHub-hosted CI status

The initial GitHub-hosted jobs did not start because of an account-level restriction. Their status is visible in Actions. The recorded passing results above are **local results**; this repository does not claim a green GitHub-hosted CI run. Workflow definitions remain available so maintainers can run them when the account allows execution.

## Not exercised

Physical-device signing/installation, signed distribution, background calls, microphone/camera media quality, real screen capture, permission-granted global hotkeys, actual notification delivery/clicks, login-cycle startup, and an authenticated private-chat session were not exercised. No private account credentials or chat screenshots are included.

No independent antivirus scan, sandbox detonation, full dependency/native-code audit, penetration test, or publisher-signature validation was performed. This is transparent local testing and bounded source inspection, not a security certification.
