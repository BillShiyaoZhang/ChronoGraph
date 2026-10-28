# ChronoGraph API v1

Production base: `https://agent-communication.online/chronograph`. JSON keys use snake_case. IDs are UUID strings; date-time inputs require a UTC offset and responses use UTC. Authenticated endpoints require `Authorization: Bearer <opaque session>`; tokens are never stored in plaintext. Error bodies use `detail: {code, message}`. Request bodies reject unknown fields and are limited to 8 MiB.

## Identity and account

- `GET /v1/auth/options` returns supported login and registration methods. Password accounts use invite-only registration.
- `POST /v1/auth/password/register {username,password,invite_code,display_name?,device_id,device_name?}` creates an account (201) and returns a session. Invites have a usage limit, expiry and revocation status; consumption and account creation are atomic. Usernames are case-insensitive ASCII letters, digits, `.`, `_` or `-`, 3–32 characters. Passwords preserve whitespace and require 12–128 Unicode characters, at most 512 UTF-8 bytes.
- `POST /v1/auth/password/login {username,password,device_id,device_name?}` returns the same session shape. Unknown accounts and wrong passwords share one error. Passwords use bounded Argon2id hashing and login attempts are rate limited.
- `POST /v1/auth/password/change {current_password,new_password}` requires a session, revokes all previous sessions and returns a replacement for the current device. A wrong current password returns 403 and preserves the existing session; expired/revoked bearer sessions return 401. Recovery is an administrator operation with a private password prompt; email recovery is not configured.
- `POST /v1/auth/apple/challenge` → `{challenge_id, nonce, expires_at}`. Set Apple's request nonce to the SHA-256 hexadecimal digest of `nonce`, and its state to `challenge_id`.
- `POST /v1/auth/apple` with `{challenge_id, identity_token, device_id, device_name?}` → `{access_token, token_type, expires_at, user:{id,display_name}, device_id}`. The five-minute challenge is single use. Production accepts only Apple's RS256 signature, issuer, configured audience, expiry and matching nonce.
- `GET /v1/me`, `PATCH /v1/me {display_name}`; `DELETE /v1/auth/session` revokes this session, `DELETE /v1/auth/sessions` revokes all sessions; `POST /v1/auth/session/rotate` atomically replaces this session.
- `DELETE /v1/me` revokes sessions, removes device/source/private-event data and grants, and cancels active meetings involving this account. A pseudonymous deleted-account stub remains in the other participants' coordination history. Apple-provider token revocation is a separate integration; no Apple password/refresh token is collected by this API.

Session responses additionally include `auth_provider: "password"|"apple"`; rotation preserves the provider. Older Apple sessions without this field are interpreted as Apple sessions by the client. Password credentials and registration invites are stored as hashes/digests, and account deletion removes password credentials. Reusing a deleted username creates a new identity without restoring previous grants.

## Device sources

`GET /v1/sources` → `[Source]`; `POST /v1/sources {id,name,device_id,upload_level?}` → Source (201). The device must match the session. `PATCH /v1/sources/{id} {name?,upload_level?}` and `DELETE /v1/sources/{id}` are owner-only.

Source: `{id,owner_id,device_id,name,upload_level,generation,coverage_start?,coverage_end?,last_synced_at?}`. Levels are `opaque` (default), `partial`, `full`. Reducing upload permission atomically removes wider fields and clamps existing shares; increasing it never upgrades an existing grant.

`PUT /v1/sources/{id}/snapshot`:

```json
{"snapshot_id":"UUID","expected_generation":0,"window_start":"2026-11-01T00:00:00Z","window_end":"2026-11-08T00:00:00Z","events":[{"id":"UUID","series_id":null,"start":"2026-11-01T09:00:00Z","end":"2026-11-01T10:00:00Z","is_all_day":false,"timezone":"UTC","availability":"busy"}]}
```

Every event must overlap the complete read window; at most 180 days and 20,000 instances. Availability: `busy|free|tentative|unavailable|unknown`. Partial adds optional `title`; Full adds optional `location,notes`. Wider fields fail 422. A successful snapshot atomically replaces all stored events for this source and increments its generation; only its latest coverage is retained. A retry with the same snapshot ID and identical body returns the existing result; a changed body or stale generation fails 409. Failed or incomplete EventKit reads must never be uploaded as empty snapshots.

Event `timezone` accepts an IANA name or a Foundation fixed-offset name: `GMT`/`UTC` followed by `+HHMM`, `-HHMM`, `+HH:MM` or `-HH:MM`, through ±18:00. For example, `GMT+0800` means UTC+08:00; IANA `Etc/GMT+8` retains its distinct UTC−08:00 meaning. The original valid name is retained in event reads. All-day ICS dates are computed in that event zone, including half/quarter-hour and negative offsets. Invalid zones fail 422 without changing the prior snapshot. Availability search and meeting timezones remain IANA-only.

`GET /v1/sources/{id}/events?start=ISO&end=ISO` is owner/grantee-only, requires covered dates and applies the effective privacy projection.

## Sharing

- `POST /v1/sources/{id}/share-links {privacy?,expires_in_days?}` → `{id,token,join_url,expires_at}` (201). Privacy defaults opaque; TTL defaults 30 days (1–365). A pairing link is for one recipient.
- `POST /v1/share-links/redeem {token}` → SharedSource. Its last URL path segment is the token. A redeemed/revoked grant cannot be restored using the old link.
- `GET /v1/shared-sources` → SharedSource list: `{id,owner_id,owner_name,name,privacy,generation,coverage_start?,coverage_end?,last_synced_at?}`.
- `GET /v1/sources/{id}/grants` → `[{user_id,privacy}]`; `DELETE /v1/sources/{id}/grants/{user_id}` revokes immediately.
- `POST /v1/sources/{id}/feed-links {privacy?,expires_in_days?}` → `{id,url,expires_at}` (201). Anyone holding this bearer URL can fetch `GET /v1/feeds/{token}.ics` until expiry/revocation. Provider and recipient refresh/cache timing is independent.
- `GET /v1/sources/{id}/share-links` and `/feed-links` → `[{id,privacy,expires_at,revoked,redeemed_by?}]`. Raw tokens are not recoverable; issue a new link if lost. `DELETE /v1/share-links/{id}` or `/v1/feed-links/{id}` revokes a link. Revoking a pairing link does not remove an already-issued recipient grant; revoke the grant separately.

## Availability and meetings

PersonSelection: `{user_id,source_ids:[UUID]}`; at least one source per person. `POST /v1/availability/search {participants:[PersonSelection],window_start,window_end,duration_minutes?,timezone?,daily_start?,daily_end?}` includes yourself and 2–20 unique people. Maximum range: 31 days. Defaults: 60 minutes, UTC, 09:00–21:00; suggested starts follow a 15-minute local grid. Missing access fails 403; missing coverage/stale data fails 409, never all-free. Freshness is a configurable 24 hours by default. Busy, tentative, unavailable and unknown block; Free does not. Confirmed ChronoGraph reservations also block. The result is still based on selected, uploaded sources, not a guarantee about undisclosed calendars.

Response: `{timezone,checked_at,windows:[{start,end,suggested_start,suggested_end}],sources:[{id,last_synced_at,generation}]}`. Windows represent continuous free intervals within daily limits; past slots are omitted.

`POST /v1/meetings {request_id,title?,start,end,timezone,participants:[PersonSelection]}` → Meeting (201). `request_id` must be a persistent UUID for that submission: retrying the exact body is idempotent; reuse with different content fails 409. One future slot, at most 24 hours. Host starts accepted; others pending. `GET /v1/meetings` lists up to 200 of your meetings; `GET /v1/meetings/{id}` returns one.

Meeting: `{id,host_id,title,start,end,timezone,revision,status,updated_at,participants:[{user_id,response}]}`. Status: `proposed|confirmed|cancelled`; response: `pending|accepted|tentative|declined`.

- `POST /v1/meetings/{id}/response {revision,response}`: acceptance rechecks your coverage/freshness/conflicts.
- `POST /v1/meetings/{id}/confirm {revision}`: host-only; all must have accepted this revision. A transaction locks participant accounts and sources, rechecks current known conflicts, reserves the slot, and creates durable projection tasks. Repeated confirmation is idempotent.
- `PATCH /v1/meetings/{id} {revision,title,start,end,timezone,participants}`: host-only, returns a new proposed revision; all responses reset, prior reservations are released and prior projections receive deletion tasks. A cancelled meeting cannot be reopened.
- `POST /v1/meetings/{id}/cancel {revision}`: host-only, idempotent; releases reservations and creates projection deletion tasks. Stale revisions fail 409 throughout.

## Durable calendar projection

`GET /v1/device-tasks?device_id=UUID` → `[{id,meeting_id,revision,action,payload,created_at}]`. Action: `upsert|delete`; payload: `{meeting_id,revision,title,start,end,timezone}`. The oldest registered device is the designated projection writer per account. Tasks remain until the same device successfully writes and acknowledges `POST /v1/device-tasks/{id}/ack` (204, idempotent). Process them in returned order. Device EventKit ownership markers use `chronograph://meeting/v1/{meeting_id}`, never the existing mirror namespace. Keep durable task→event mappings and do not overwrite unrelated or manually changed events. Account confirmation and device-calendar delivery are separate statuses.

## Operations

Run `alembic upgrade head` before serving `app.main:app`. No production auto-create, development login, fake Apple key or test-user endpoint exists. `/healthz` is liveness; `/health/ready` checks database and migrated schema. Run one worker for this beta host; login/challenge rate limits are bounded in-process. Disable access logs at both proxy and Uvicorn for token-bearing URL paths. Tests inject only a local test JWKS key; application production verification code remains unchanged.
