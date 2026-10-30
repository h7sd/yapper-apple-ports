# Public evidence summary

The supplied `Yapper-Setup.AppImage` is 117,342,908 bytes with SHA-256 `e54f1d3f638caeae0302c6e56bbcf5c272a774862aecafd3d4959bb8e5095b12`.

REA 6.5.0 analyzed the recovered application-owned `package.json`, `main.js`, `preload.js`, and `games.js`. Evidence ID: `ev_0f16c07674f1b813c3c3f2bd23b75475c4cd45cdad7b30cb3b2fb7098256d573`. The analysis read 51,342 text bytes, parsed three JavaScript files with no parse failures, and left 256 other files unselected. The Electron version `38.8.6` was recovered from a literal runtime string in the Linux ELF executable without running that executable.

This was static analysis of selected recovered source. It did not analyze the remote website, all third-party dependencies, the Electron/native binaries in full, or traffic during real calls. Finding counts are analysis output rather than a safety score. The analysis does not establish an absence of malicious behavior or vulnerabilities.

The raw REA JSON and local runtime report contain workstation-specific paths and are intentionally omitted from this public source tree. Their absence limits independent inspection of the original detailed analysis. The preserved `upstream/` files and hashes in `provenance.json` allow the published source relationship to be checked directly. Current source and package checks are reproducible through `scripts/verify-macos.mjs` at the repository root and the GitHub Actions workflow.
