# Native iOS surface

Mode: Operate. The first milestone supports sign-in, selecting a conversation and reading/sending text messages. Its visual authority is Yapper's existing UI and the user's confirmed request to retain that identity.

Use the existing Yapper app mark and warm accent. Native colors and dark surfaces inherit the publicly shipped Yapper palette; system text styles and SF Symbols provide legible, Dynamic Type-aware controls. Navigation uses a native stack, with a centered account summary and standard sheets for account/settings. Do not add a fabricated server list or dead call/plugin actions.

Keep the main content and its background continuous behind system bars, with interactive content inside the safe areas. The account row must remain centered at Pro Max widths and reflow for large accessibility text. Inputs, keyboard avoidance, edge-swipe navigation and focus use native behavior. Loading, empty, error and failed-send states must be visible and recoverable. Synthetic QA conversations must be explicitly labeled and reachable only in Debug builds.

The welcome screen contains the Yapper mark, localized welcome title, and one sign-in button. Terms and privacy links remain visible at the bottom. Do not include the earlier promotional or preview paragraphs, or native username/password fields. The user approved a temporary official web login for authentication and CAPTCHA; this is the only website surface. After authentication, dismiss it and show the native conversation list. Native chat history, composer and account settings remain SwiftUI. Native layout adapts to iPhone and iPad without fixed web viewport dimensions.
