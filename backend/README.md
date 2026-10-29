# ChronoGraph cloud beta

Optional accounts, consented device snapshots, account-to-account sharing, read-only ICS feeds, common-time queries, and versioned meeting responses. Existing on-device image export and iCloud mirroring remain independent. This service does not connect directly to private calendar-provider accounts or make EventKit an always-online source. See [API contract](CONTRACT.md).

## Deployment

- API: `https://agent-communication.online/chronograph/`
- Readiness: `/health/ready`; liveness: `/healthz`.
- Host root: `/opt/chronograph`; initial release: `releases/20261028-initial`; active release: `current` symlink.
- Active deployment (2026-10-29): `releases/20261029-multi-source-rules`, API image `chronograph-api:20261029-multi-source-rules`, Alembic head `a64c31e8f902`.
- Compose project: `chronograph`. Database has no public port; API binds to loopback port 18084 and the existing nginx ingress network.
- Private environment: `/opt/chronograph/secrets.env` (0600). Generate credentials on the server; never commit or print them.
- Shared host: 2 vCPU / approximately 2 GiB RAM. API cap: 320 MiB, one worker, four concurrent requests. Database cap: 256 MiB. New logs rotate at 2 × 5 MiB. These are beta limits, not a capacity guarantee.

```sh
docker compose --project-name chronograph \
  --env-file /opt/chronograph/secrets.env \
  -f /opt/chronograph/current/backend/compose.yml up -d --build
```

The entrypoint applies Alembic migrations. Back up the existing HTTPS server configuration before adding `nginx-location.conf`, run `docker exec agent-nginx nginx -t`, then gracefully reload nginx. Never restart or recreate other projects' containers. Runtime Docker DNS resolves only this location's upstream, so API startup/IP changes cannot prevent the other sites' proxy from starting. Confirm `TRUSTED_PROXY_IPS` matches nginx's ingress-network address.

Requests under `/chronograph/` are excluded from nginx path logs because subscription/pairing paths carry bearer tokens. API access logs are disabled and validation errors exclude rejected credential/event input. Do not enable SQL, body or token logging in production.

## iOS setup and limits

1. Username/password accounts work with the free Personal Team build. Registration requires a server-created invite. Optional **Sign in with Apple** still requires a matching paid-team entitlement/profile; native identity tokens are checked against Apple's keys, issuer, audience and one-use nonce. No production debug login exists.
2. Settings → Cloud collaboration (beta) uses the configurable `ChronoGraphAPIBaseURL` above. HTTPS is required, with no authentication redirects.
3. Sign in, name a sharing configuration, choose one or more local calendars, dates and default content, then preview single-occurrence/series exceptions and approve the reviewed upload. The same calendar can belong to independent configurations. Controls support rolling/fixed dates up to the existing 180-day snapshot limit and 20,000 uploaded events per snapshot. Existing bindings retain their single calendar, content level and preceding-seven/following-ninety-day range. Source bindings and rule metadata are device-specific; original event text is not persisted in those rules.
4. Pairing links grant signed-in accounts access; public ICS links grant their holders read access. Treat both as secrets and revoke when no longer needed.
5. Find candidates and propose a slot. Responses bind to a revision; the host confirms after everyone accepts. First calendar insertion is explicit. Existing app-owned, unmodified projections can subsequently reconcile; manual changes are preserved for the user to handle.

Cloud and iCloud use the same occurrence/series rule controls, with separate rules for each configuration. An event excluded from an iCloud mirror is not automatically excluded from an independently selected cloud configuration. Cloud exclusions omit the event from the uploaded snapshot and therefore from availability calculations through that source. The source field ceiling is calculated from the configuration's default and exceptions; per-event `visibility`, the source ceiling and recipient permissions all limit JSON/ICS output. Older clients can omit `visibility` and retain their previous source-level behavior.

Private provider OAuth/CalDAV connections and arbitrary external ICS ingestion are not part of this deployment. APNs credentials are not configured; clients refresh through authenticated requests and permitted device execution. No fixed background interval or delivery guarantee is promised. Apple's account authorization is separate from deleting a ChronoGraph account; full Apple provider token revocation requires its developer credentials.

## Password accounts and private registration

`GET /v1/auth/options` advertises password login and invite-only registration. `POST /v1/auth/password/register` accepts username, password, invite_code, optional display_name, device_id and device_name. `POST /v1/auth/password/login` accepts username, password, device_id and device_name. Both return the normal opaque bearer session plus `auth_provider: "password"`. `POST /v1/auth/password/change` requires the current bearer session and current_password/new_password; it revokes every old session and returns a replacement for the current device. Apple sessions report `auth_provider: "apple"`; rotation preserves the provider.

Usernames contain 3–32 ASCII letters, digits, dots, underscores or hyphens, and are trimmed/lowercased. Passwords preserve all spaces and Unicode, contain 12–128 characters and at most 512 UTF-8 bytes, and are stored only as salted Argon2id hashes (19 MiB, two iterations, one lane). Hash work is limited to two simultaneous operations, with IP/account rate limits before hashing. Registration invite secrets are random, stored only as SHA-256 digests, expire, can be revoked and have an atomic usage limit. There is no public registration switch or email password recovery. A server administrator can reset a password after independently verifying the account owner.

Run the administrator CLI inside the current API container with its private database environment. `create-invite` deliberately prints the secret once; redirect stdout to an owner-only file and share it privately. Never include secrets in shell arguments, access logs, Git or public screenshots.

```sh
python -m app.accounts create-invite --days 7 --uses 1
python -m app.accounts revoke-invites
python -m app.accounts revoke-invites --id INVITE_UUID
python -m app.accounts reset-password USERNAME
```

`reset-password` prompts using `getpass` and revokes all sessions. Usernames/password accounts are separate from Apple identities; this release does not link or merge them. Deleting an account deletes its password credential; registering the same username creates a new identity and cannot recover old sharing grants. Apply a database backup before upgrading. Downgrading the password migration is blocked while password accounts exist; recover a compatible application release rather than deleting users.

## Data boundaries

Opaque uploads contain timing, timezone, all-day and availability plus opaque identity mapping. Partial adds title; full adds location and notes. Original URLs, attendees, organizers, alarms and attachments are not uploaded. More permissive sharing cannot recreate unuploaded fields. Snapshot commits use generation checks and transactions; reading failures must never be sent as empty successful reads. Missing coverage or stale data produces a recoverable status, not free time.

PostgreSQL owns meeting/response/reservation state. Calendar writes are asynchronous and not atomic with PostgreSQL. Confirmation records app agreement, not perfect knowledge of all external calendars. Downloaded feeds and images cannot be recalled.

## Backup and recovery

`/opt/chronograph/current/backend/backup.sh` creates an owner-only custom-format dump in `/opt/chronograph/backups` and keeps fourteen completed dumps. Its isolated daily host schedule lives at `/etc/cron.d/chronograph`.

Local dumps do not protect against loss of this server or disk. An off-host backup destination and encryption credentials still need configuration before durable production use. Export only to a private location; never to Git, a public bucket or chat attachments.

Test restoration into a separate temporary database with `pg_restore --exit-on-error`, never over `chronograph`. Preserve the private environment and named database volume. Never run `docker compose down -v`, global container/volume pruning, or direct Docker-store deletion.

## Validation

```sh
uv sync --locked --group dev
uv run pytest
```

Tests use synthetic data and injected test verifiers; they never read real calendars or enable a runtime authentication bypass. Check PostgreSQL migrations/locking as well as SQLite unit tests. Native Apple login, EventKit authorization and cross-device behavior require device acceptance.
