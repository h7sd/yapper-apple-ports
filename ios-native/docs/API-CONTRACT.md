# Yapper/Yapin native client contract

Observed on 30 October 2026 from public shipped JavaScript. This document is a compatibility snapshot, not an official API specification. A fully native client can reproduce the observed HTTPS and WebSocket calls, but production sign-in may require a browser challenge that this milestone deliberately does not bypass.

## Evidence and scope

REA CLI `rea-agents@6.5.0` analyzed the public application tree as inert text. Evidence ID: `ev_e2e4db31d9121e7e40e757b4238ff70e4ca225058492b006cc473d233b1d4622`; artifact manifest SHA-256: `c754f07311551ac8d21f53e3a58a7c32399e1f40d75f43e4971b14b4d1c3bb78`. No MCP tools were connected, so the CLI fallback was used without changing client configuration. REA's AST/graph coverage is incomplete; four inline HTML bodies were not analyzed. Static relationships do not establish runtime execution.

Focused manual reading supplied the contract below. Seven relevant bundles were fetched again from their public URLs and matched the previously downloaded bytes exactly. [api-evidence.json](api-evidence.json) records source URLs, SHA-256 digests, token locations, evidence type and remaining unknowns. Offsets are Unicode character offsets, not byte offsets. No user cookies, account tokens, private sessions, real messages or personal screenshots were accessed. No login, message send or account mutation was performed during this investigation.

## Origins and authentication

Observed configuration in `1b5f2lvdqu1w3.js`, module 61664:

- Web origin: `https://yapin.gg`; legacy aliases include `https://www.yapper.website` and `https://yapper.website`.
- Supabase: `https://dnfkuqzddwvtdojzgmdm.supabase.co`.
- Optional PostgREST alternative: `https://api.yapper.website`, enabled by the `api_hetzner` feature flag. The web client rewrites `/rest/v1/` calls and falls back to Supabase after qualifying failures. A native client may use the canonical Supabase origin directly; this is an implementation choice, not an observed native client.
- Realtime: `wss://rt.yapper.website/ws`.
- Public anonymous project key and Turnstile site key are embedded in module 61664. The anonymous key is public application configuration, **not** a user access token or privileged service-role key.

Supabase requests carry `apikey: <public anonymous key>`. Authenticated requests also carry `Authorization: Bearer <current user access token>` and JSON requests use `Content-Type: application/json`. The web client treats access tokens and refresh tokens as a session. Native code must keep these in Keychain, redact them from logs and replace both tokens after refresh/MFA; no browser storage is imported.

### Password login

Observed call sites in `0-lokdq9a6g34.js`:

1. Email-shaped identifiers call Supabase password sign-in with a lowercase email. Underlying shipped SDK sends `POST /auth/v1/token?grant_type=password` with `{ "email": "...", "password": "...", "gotrue_meta_security": { "captcha_token": "..." } }`. The CAPTCHA value may be absent at the SDK type level; that does **not** prove server acceptance without it.
2. Other identifiers call `POST https://yapin.gg/api/login` with `{ "username": "...", "password": "...", "captchaToken": "..." }`. The caller requires successful HTTP status plus both `access_token` and `refresh_token`, then sets the Supabase session. Error text is in `error`.
3. Token responses provide `access_token`, `refresh_token`, `expires_in` and `user` (including `id`). `expires_at` can be derived from receipt time plus `expires_in` when absent.
4. Refresh: `POST /auth/v1/token?grant_type=refresh_token` with `{ "refresh_token": "..." }`.
5. Authenticated current user: `GET /auth/v1/user`, returning the user object, including `id`, email and `factors` where available.
6. SDK logout calls `POST /auth/v1/logout?scope=<scope>` with the current bearer. Signing out locally and discarding the local session remains necessary even if the network fails. Other-device/global logout is a separate user action.

The username fetch uses normal same-origin browser defaults. A separate `yd` device cookie exists in the web application, with a `note_device` RPC. The scoped login call does not explicitly construct a CSRF header. Server-side CSRF/device policy was not inspected, so its absence must not be asserted.

### CAPTCHA: explicit compatibility limit

The shipped web login always obtains a Cloudflare Turnstile token when its bundled site key is present. It loads `https://challenges.cloudflare.com/turnstile/v0/api.js`, renders a widget and waits for a token before password sign-in. That is an observed browser dependency, not an optional decorative component.

A public `GET /auth/v1/settings` with the public anonymous key succeeded. It reported email and Google enabled and native Supabase passkeys disabled. It contained **no CAPTCHA configuration fields**. Therefore current backend enforcement is **unknown**, not disabled. No credentialed probe was made.

Cloudflare documents that Turnstile requires a browser environment and does not run natively; its mobile recipe embeds a WebView. Supabase's Swift password API accepts a supplied CAPTCHA token but does not generate a native challenge itself. See [Cloudflare mobile implementation](https://developers.cloudflare.com/turnstile/get-started/mobile-implementation/), [Supabase CAPTCHA configuration](https://supabase.com/docs/guides/auth/auth-captcha) and [Supabase Swift password sign-in](https://supabase.com/docs/reference/swift/auth-signinwithpassword).

This no-WebView milestone cannot complete a required Turnstile challenge. On that response, the client must explain the limitation clearly and retain no fake signed-in state. Opening the official website is informational and does not sign the native client in. A future supported browser handoff/one-time code or native authentication route would require cooperation from the service operator; none was established by this investigation. Do not fabricate a callback, borrow browser tokens, spoof a solved CAPTCHA, alter server protection or claim ordinary password login was verified.

### TOTP two-factor authentication

Observed app code lists verified `totp` factors and uses Supabase `challengeAndVerify`. The shipped SDK implements:

- List: `GET /auth/v1/user`; inspect `factors` for `{ "id": "...", "factor_type": "totp", "status": "verified" }`.
- Challenge: `POST /auth/v1/factors/<factor-id>/challenge` with the lower-assurance bearer and `{ "factorId": "<factor-id>" }`. Response includes `id` (challenge ID), `type` and expiry information.
- Verify: `POST /auth/v1/factors/<factor-id>/verify` with `{ "challenge_id": "<challenge-id>", "code": "123456" }`. Successful response is a replacement session. Persist the returned tokens before loading account data.

The web SDK determines a required upgrade from JWT `aal` and verified factors. Its REST wrapper also recognizes HTTP 403 containing `Finish signing in with your 2FA code`. Recovery flows, passkeys, Google sign-in and enrollment are outside this milestone; their presence in the website does not establish native implementation.

## Initial account and DM list

`POST /rest/v1/rpc/bootstrap` (empty JSON object) returns a JSON object consumed by the web app. For this milestone, relevant fields are:

- `profiles`: array of profile objects.
- `dm_channels`: array of DM/group channel objects.
- `dm_members`: array of `[channel-id, user-id]` tuples.
- `unread`: array of `{ "channel_id": "...", "unread": number, "mentions": number, "muted": boolean }`.
- `servers`, `channels`: arrays of joined server objects and server channel objects.

Other observed fields include member/role/category maps, friends, blocks, flags, moderation state and calls. They need not all be modeled for the first native chat milestone. Use tolerant decoding for extra fields; do not silently accept malformed IDs or substitute unrelated data.

Channels are keyed by `id`. Observed fields consumed by UI/state include `kind`, `server_id`, `name`, `icon_path`, `last_message_at`, `created_by`, `parent_id`. Kinds include `dm`, `group`, `text`, `voice`, `thread`, `forum`. A null `server_id` is used for DMs/groups. The direct peer is the member whose ID differs from the current user. Group display names use the channel name or member names. Sort conversations by `last_message_at` descending.

A fallback DM list is explicitly present when bootstrap is unavailable:

1. `GET /rest/v1/channel_members?select=channel_id,hidden_at&user_id=eq.<user-id>`.
2. `GET /rest/v1/channels?select=*&id=in.(<channel-ids>)`.
3. `GET /rest/v1/channel_members?select=channel_id,user_id&channel_id=in.(<channel-ids>)`.
4. Fetch member profiles by their IDs.

The web client hides a non-server channel when membership `hidden_at` exists and `channel.last_message_at <= hidden_at`. A missing/empty membership result is not proof the user has no chats: the original retries an unexpected empty result once after checking the session.

Creating/opening a new DM uses `POST /rest/v1/rpc/get_or_create_dm` with `{ "other": "<peer-user-id>" }`, returning a channel ID. It can require a separate bot challenge or reject because of privacy/block rules. New-DM creation is optional beyond the existing-conversation milestone; permission failures must remain visible.

## Profiles and media

The web app selects these public profile fields: `id,username,created_at,bio,avatar_path,banner_path,banner_x,banner_y,avatar_x,avatar_y,avatar_zoom,avatar_rot,banner_zoom,links,verified_as,verified_hidden,badges,display_name,pronouns,accent_color,accent_color2,plus_until,plus_badge_hidden,dms_from,server_tag,tag,shown_badge,verify_required,custom_status,avatar_deco,profile_effect,name_banner,discriminator,avatar_revert_at,name_style,account_level,plus_since,gifts_given`.

Current profile can be read using `GET /rest/v1/profiles?select=<required-fields>&id=eq.<authenticated-user-id>`; the normal array response is empty if no visible profile exists. The web app uses `maybeSingle`; this is an SDK response transformation and does not change table identity. Minimal native models can select fewer fields rather than guessing the types of unused decorations.

The current public media helper maps `avatars`, `banners`, `icons`, `emojis`, `attachments` to:

`https://files.yapper.website/<bucket>/<path with each segment URL-encoded>`.

The public fallback is `https://pub-f2aa8df0443d41d3882353e43988c5bb.r2.dev/<bucket>/<path>`. Other buckets use the Supabase `/storage/v1/object/public/<bucket>/<path>` route. A path starting with `/` is treated by the browser as relative to the current web origin. Native resolution must retain HTTPS and known public origins, and must never attach user bearer tokens to CDN image requests.

## Message history, sending and catch-up

History is `POST /rest/v1/rpc/channel_messages` with `{ "cid": "<channel-id>", "before": null, "lim": 50 }`. Older history supplies the oldest loaded `created_at` value as `before`. Response is `{ "messages": [ ... ], "profiles": [ ... ], "reactions": [ ... ] }`. The original merges profiles and sorts messages chronologically by `created_at`. Message IDs are stable UUIDs; merge by ID, not by timestamp alone.

Observed message fields include `id`, `channel_id`, `author_id`, `content`, `created_at`, nullable `edited_at`, nullable `reply_to_id`, nullable `attachment_path`, `attachment_width`, `attachment_height`, optional `attachment_name`, `attachment_size`, `voice_secs`, `voice_wave`; optional bot/webhook/embed fields also occur. Pending, failed and local file URLs are client-only properties and must not be sent as database columns.

Text sending uses `POST /rest/v1/messages?select=*`, `Prefer: return=representation`, `Accept: application/vnd.pgrst.object+json`, with:

```json
{
  "id": "<client-generated UUID>",
  "channel_id": "<selected channel UUID>",
  "author_id": "<authenticated user UUID>",
  "content": "Trimmed message text"
}
```

`reply_to_id` is optional. **Do not send a client `created_at`**; the canonical returned row supplies it. The original gives insertion 20 seconds, displays a pending row and marks failures explicitly. A duplicate-key `23505` response leads to reading the same message ID; this avoids creating a second message after an uncertain response. A native retry must reuse the same UUID. Do not retry arbitrary mutations with new IDs or erase the draft on failure.

Default web text limit is 2,000 UTF-16 code units, counting custom emoji markup as its display `:name:` form. A 4,000 limit is enabled only when the `plus_4000` feature flag and active `profile.plus_until` both apply. Server permissions/content moderation remain authoritative. Attachment upload and voice recording are separate features; displaying an existing attachment does not establish upload support.

Reconnect catch-up uses `POST /rest/v1/rpc/channel_messages_since` with `{ "cid": "...", "since": "<last confirmed timestamp>", "lim": 50 }`, returning a bundle with messages/profiles/reactions. At the 50-row cap the original reloads the latest page. A native client can instead reload the latest 50 on every reconnect to avoid silently missing a long gap; that is an explicit implementation choice. Latest-page history is safer than claiming complete recovery from an unbounded event stream.

Mark-read is `POST /rest/v1/rpc/mark_read` with `{ "cid": "..." }`. It is an account mutation and should only happen when the user actually opens/views the conversation, not during offline fixture verification.

## Custom realtime protocol

This application uses its own JSON WebSocket protocol, **not** Supabase Phoenix channel frames. Module 37358 in `1hu0uktie-cf6.js` establishes:

1. Open `wss://rt.yapper.website/ws` with no bearer in the URL.
2. Send `{ "type": "auth", "token": "<access-token>" }` after open.
3. Wait for `{ "type": "auth", "ok": true }` before subscribing. An unsuccessful auth causes close.
4. Send `{ "type": "subscribe", "topics": ["all", "user:<authenticated-user-id>"] }`. Joined servers add `server:<id>`; an active server text/thread channel adds `chan:<id>`. DM messages arrive on the user topic; a DM must not depend on a fabricated `dm:` topic.
5. Receive `{ "type": "subscribed", "ok": ["..."], "no": ["..."], "retry": ["..."] }`; only `ok` confirms permission. Revocations use `{ "type": "revoked", "topics": ["..."] }`. Unsubscribe with `{ "type": "unsubscribe", "topics": ["..."] }`.
6. Send `{ "type": "ping" }` every 25 seconds while active; replies use `{ "type": "pong" }`. The original closes/reconnects a previously responsive connection after a 75-second silence. Suspend in background and resync after foreground rather than promising background socket persistence.
7. On token refresh send a new auth frame on the existing connection. The client also reconnects with bounded exponential backoff and jitter after closure.

Message events have this envelope (synthetic values only):

```json
{
  "type": "event",
  "event": "message",
  "topic": "user:<user-id>",
  "payload": {
    "table": "messages",
    "operation": "INSERT",
    "record": { "id": "...", "channel_id": "...", "author_id": "...", "content": "...", "created_at": "..." },
    "old_record": null
  }
}
```

`UPDATE` merges the returned record; `DELETE` removes `old_record.id`. Events must match an authenticated/subscribed scope and known conversation. Unknown JSON events should be ignored safely, not interpreted as new messages. Other event names include reactions, unread counters, channels, membership, moderation and typing. Their presence does not mean this native milestone implements every site behavior.

## What is established and what remains unknown

**Established statically:** origins, standard token exchange and refresh calls, username login call, TOTP challenge/verify, bootstrap consumer shape, DM list fallback, history/send routes, basic profile/message fields, media helper and custom realtime frames. Fresh public bytes confirm these sources were still served on the inspection date.

**Inferred from consumers:** field nullability/types beyond explicit conditions, stable UUID use across all server responses, server defaults and exact ordering inside a bundle. Implement tolerant but safe decoding; native contract tests use synthetic fixtures and do not count as live server validation.

**Not established:** credentialed production sign-in (especially CAPTCHA enforcement), native browser handoff, account-specific row-level policies, an actual live message send/receive, background push delivery, calls, media upload, complete server management or JavaScript plugin support. Those cannot be described as verified from this research.
