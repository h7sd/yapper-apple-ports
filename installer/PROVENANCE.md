# Installer provenance and licensing boundary

The upstream workflow reference was [Vencord/Installer](https://github.com/Vencord/Installer), inspected at commit `595991ca27520868af4f9c48adf0c53ee971f1f2`. Its Go source headers identify **GPL-3.0** and credit **Vendicated and Vencord contributors**; its LICENSE contains GNU GPL version 3. Its README describes installing Vencord into Discord.

This YapperCord installer is an independently implemented SwiftUI/Foundation GUI, CLI, ASAR metadata reader, and reversible file-operation engine. No Go implementation, upstream installer binary, patcher, downloader, self-updater, or visual assets from Vencord/Installer are included. It shares the general select/install/uninstall workflow and is not the official Vencord Installer. It cannot install Vencord into Discord or make Discord-specific plugins compatible with Yapper.

The independently authored installer code is provided under the [MIT license](LICENSE). This distinction does not relicense upstream Vencord or the upstream Installer. If code from either project is incorporated later, its license and corresponding source/distribution obligations must be assessed and preserved. No license grant for Yapper's recovered code, branding, bundled runtime dependencies, or remote service is implied here.

A compatible Yapper app optionally bundled with a release has its own provenance and dependencies recorded in the repository's macOS source. Its built-in plugin runtime is supplied by that app; the installer only validates/copies the app and changes a local enablement configuration. Signature checks, catalog metadata, and tests are not a malware-free guarantee.
