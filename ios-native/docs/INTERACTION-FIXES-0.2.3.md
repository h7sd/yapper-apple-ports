# Reported iOS interaction fixes — 0.2.3

This development update keeps the 0.2.2 native home arrangement. It addresses four reported failures without adding a web application to the native screens. The temporary official login/CAPTCHA component remains the approved exception.

## Back requires repeated taps

The compact header previously gave a plain chevron a larger layout frame without an explicit rectangular hit shape. Its replacement has a 48×48-point rectangular target. It dismisses composer focus and closes/cancels the active conversation immediately. Compact navigation now updates its path directly, removing an asynchronous selection observer that could push a conversation after Back. A late read callback cannot mark a conversation already closed by the user. Drafts survive reopening.

`NativeInteractionRegressionTests` taps three different edges of the control with the keyboard open. The wide layout exercises its existing Home navigation instead.

## Own banner says “Angemeldet” rather than Online

Own availability is an account preference, separate from peer socket presence and notification permissions. `NativePresence.swift` reads the authenticated `my_status_pref` RPC independently. It accepts Online, Idle, DND and Invisible. The inspected official frontend (`43b-2yp9vd3z_.js`, module 41958, `syncStatusFromAccount`) retains the local preference for a successful JSON null; a fresh state starts Online. Empty/malformed responses and HTTP failures do not establish Online.

Same-account known preferences survive profile/list replacement and failed optional reads. The settings action applies a new choice only after its explicit server write succeeds. Invisible is labeled “Unsichtbar” in the own banner; its public appearance remains offline. A committed-preference revision prevents an older sound-policy request from overwriting a later DND choice, and the actual playback gate checks the latest DND state again.

This fixes the displayed own preference, not full global presence publishing or every idle-state behavior.

## Gallery photos and videos cannot be attached

The composer offers the native PhotosUI picker alongside Files. It filters photos/videos and grants the app access only to the selected item; there is no broad photo-library permission request. The provider's temporary representation is copied during its valid lifetime, imported away from the main actor, then removed. Cancellation and late callbacks cannot replace an existing pending attachment.

Supported image data and animations are preserved. HEIC/unsupported still images and oriented stills are converted to an upright JPEG with a maximum 4096-pixel dimension. Live Photos select their still image. MOV/MP4/WebM retain the applicable video MIME type. Imports enforce the existing 10 MB upload policy before and during reading. Gallery selections enter the same pending-attachment and upload/media-scan path as Files; selection alone never sends a message.

`NativeGalleryImportTests` covers representation lifetime, size rejection, cancellation cleanup, real HEIC orientation, MIME types and filenames. Simulator interaction fixtures use public test assets, not a user's private library. Live account upload/scan acceptance remains unverified.

## Sent message produces “no valid response”

The native sender generated uppercase UUID text while PostgreSQL returned lowercase UUID text. A strict string comparison rejected the acknowledgment even though the insert had succeeded. The official sender (`3-pd02a6i86ee.js`) uses `crypto.randomUUID()` and requests the inserted row; its duplicate-key recovery fetches the existing row by ID.

The native sender now generates lowercase UUIDs and compares valid UUID identities structurally. An acknowledgment must match the exact message, channel and author and include a valid server timestamp. Valid object and single-row array responses are accepted. An empty, malformed or ambiguous successful response, or a duplicate conflict, triggers at most one identity-scoped read for the already-created message. It never triggers another insert. Real authorization failures remain errors. Replies and attachments share this acknowledgment logic.

Accepted rows become canonical lowercase IDs before merging with history/realtime. A successful send clears only the matching original draft. A failed confirmation retains the same pending message ID for retry, preventing a second identity from being created just because an acknowledgment was lost.

`NativeSendConfirmationTests`, `NativeMessageFeatureTests` and `NativeUserReportRegressionTests` use injected synthetic transports. They do not send to a real conversation.

See the [0.2.3 validation report](../reports/native-0.2.3-validation.json) for actual test runs, artifact checks and remaining verification limits.
