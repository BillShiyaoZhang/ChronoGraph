from datetime import datetime, timedelta
import hashlib
import json
import secrets
from uuid import UUID
from fastapi import FastAPI, Depends, Request, Response, Query
from fastapi.responses import JSONResponse, PlainTextResponse
from fastapi.exceptions import RequestValidationError
from sqlalchemy import select, delete, update, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session
from .config import Settings
from .database import make_engine, make_sessions
from .models import (User, Device, LoginChallenge, SessionToken, PasswordCredential, RegistrationInvite, Source, BusyEvent, Grant, ShareLink,
                     Meeting, Participant, Reservation, DeviceTask, now, uid)
from .schemas import (AppleLogin, PasswordLogin, PasswordRegister, PasswordChange, UserPatch, SourceCreate, SourcePatch, Snapshot, LinkInput, Redeem,
                      Search, MeetingCreate, MeetingPatch, MeetingResponse, Version, PersonSelection)
from .security import (get_db, session_auth, AppleVerifier, PasswordSecurity, RateLimiter, secret, digest, aware, fail, issue_session)
from .services import (PRIVACY_RANK, source_json, shared_json, owner_source, check_level, accessible_sources,
                       search_windows, busy_ranges, meeting_json, visible_meeting, check_revision,
                       projection_tasks, ics_document)


def create_app(settings: Settings | None = None, engine=None):
    settings = settings or Settings.from_env()
    app = FastAPI(title="ChronoGraph", version="0.1.0", root_path=__import__("os").getenv("ROOT_PATH", ""))
    app.state.settings = settings
    app.state.engine = engine or make_engine(settings.database_url)
    app.state.sessions = make_sessions(app.state.engine)
    app.state.apple_verifier = AppleVerifier(settings.apple_audience)
    app.state.rate_limiter = RateLimiter()
    app.state.password_security = PasswordSecurity()

    @app.get("/")
    def information():
        return {"service": "ChronoGraph", "version": "0.1.0", "status": "running", "api": "v1"}

    @app.exception_handler(RequestValidationError)
    async def validation_error(_, exc):
        # Pydantic's default errors echo rejected input, potentially including credentials/notes.
        issues = [{"loc": e["loc"], "type": e["type"], "msg": e["msg"]} for e in exc.errors()]
        return JSONResponse(status_code=422, content={"detail": {"code": "invalid_request", "message": "Request validation failed", "issues": issues}})

    @app.exception_handler(IntegrityError)
    async def integrity_error(_, exc):
        return JSONResponse(status_code=409, content={"detail": {"code": "conflict", "message": "The operation conflicts with existing data"}})

    @app.middleware("http")
    async def request_limits(request, call_next):
        if request.method in {"POST", "PUT", "PATCH"}:
            maximum = 8 * 1024 * 1024
            try:
                if int(request.headers.get("content-length", "0")) > maximum:
                    return JSONResponse(status_code=413, content={"detail": {"code": "payload_too_large", "message": "Request exceeds 8 MiB"}})
            except ValueError:
                return JSONResponse(status_code=400, content={"detail": {"code": "invalid_request", "message": "Invalid content length"}})
            body = bytearray()
            async for chunk in request.stream():
                body.extend(chunk)
                if len(body) > maximum:
                    return JSONResponse(status_code=413, content={"detail": {"code": "payload_too_large", "message": "Request exceeds 8 MiB"}})
            request._body = bytes(body)
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.get("/healthz")
    @app.get("/health/live")
    def live():
        return {"status": "ok"}

    @app.get("/health/ready")
    def ready(db: Session = Depends(get_db)):
        try:
            db.execute(text("SELECT 1"))
            db.execute(select(User.id).limit(1))
        except Exception:
            return JSONResponse(status_code=503, content={"status": "unavailable"})
        return {"status": "ok"}

    @app.get("/v1/auth/options")
    def auth_options():
        return {"password_enabled": True, "registration_mode": "invite",
                "password_min_length": 12, "password_max_length": 128}

    def password_limit(request, username, bucket):
        app.state.rate_limiter.check(request, bucket, limit=20)
        app.state.rate_limiter.check(request, "password_account", limit=10,
                                     identity="account:" + digest(username))

    def bind_device(db, user, payload):
        device_id = str(payload.device_id)
        device = db.get(Device, device_id)
        if device and device.user_id != user.id:
            fail(409, "device_in_use", "This device identifier belongs to another account")
        if device is None:
            db.add(Device(id=device_id, user_id=user.id, name=payload.device_name))
            db.flush()
        return device_id

    @app.post("/v1/auth/password/register", status_code=201)
    def password_register(payload: PasswordRegister, request: Request, db: Session = Depends(get_db)):
        password_limit(request, payload.username, "password_register")
        # A conditional UPDATE makes invite consumption atomic on PostgreSQL and SQLite.
        # Any later failure rolls this transaction back, including username/device conflicts.
        claimed = db.execute(update(RegistrationInvite).where(
            RegistrationInvite.digest == digest(payload.invite_code.get_secret_value()),
            RegistrationInvite.revoked.is_(False), RegistrationInvite.expires_at > now(),
            RegistrationInvite.uses < RegistrationInvite.max_uses
        ).values(uses=RegistrationInvite.uses + 1).returning(RegistrationInvite.id)).scalar_one_or_none()
        if claimed is None:
            fail(401, "invalid_invite", "Registration invite is invalid, expired or already used")
        if db.scalar(select(PasswordCredential.user_id).where(PasswordCredential.username == payload.username)):
            fail(409, "username_unavailable", "This username is unavailable")
        user = User(display_name=(payload.display_name or "").strip() or payload.username)
        db.add(user)
        db.flush()
        device_id = bind_device(db, user, payload)
        encoded = app.state.password_security.hash(payload.password.get_secret_value())
        db.add(PasswordCredential(user_id=user.id, username=payload.username, password_hash=encoded))
        result = issue_session(db, user, device_id, settings, "password")
        db.commit()
        return result

    @app.post("/v1/auth/password/login")
    def password_login(payload: PasswordLogin, request: Request, db: Session = Depends(get_db)):
        password_limit(request, payload.username, "password_login")
        credential = db.scalar(select(PasswordCredential).where(PasswordCredential.username == payload.username))
        user = None
        if credential is not None:
            # User lock serializes logins, password changes, resets and account deletion.
            user = db.scalar(select(User).where(User.id == credential.user_id).with_for_update())
            credential = db.scalar(select(PasswordCredential).where(
                PasswordCredential.user_id == credential.user_id).execution_options(populate_existing=True))
        encoded = credential.password_hash if credential and user and not user.deleted else None
        if not app.state.password_security.verify(encoded, payload.password.get_secret_value()):
            fail(401, "invalid_credentials", "Username or password is incorrect")
        if app.state.password_security.hasher.check_needs_rehash(encoded):
            credential.password_hash = app.state.password_security.hash(payload.password.get_secret_value())
        device_id = bind_device(db, user, payload)
        result = issue_session(db, user, device_id, settings, "password")
        db.commit()
        return result

    @app.post("/v1/auth/password/change")
    def password_change(payload: PasswordChange, request: Request, auth=Depends(session_auth), db: Session = Depends(get_db)):
        user, token = auth
        db.scalar(select(User).where(User.id == user.id).with_for_update())
        if db.scalar(select(SessionToken.digest).where(SessionToken.digest == token.digest)) is None:
            fail(401, "unauthorized", "Session has expired or was revoked")
        app.state.rate_limiter.check(request, "password_change", limit=10)
        app.state.rate_limiter.check(request, "password_account", limit=10, identity="user:" + user.id)
        credential = db.get(PasswordCredential, user.id)
        if not app.state.password_security.verify(credential.password_hash if credential else None,
                                                   payload.current_password.get_secret_value()):
            fail(403, "invalid_credentials", "Current password is incorrect")
        credential.password_hash = app.state.password_security.hash(payload.new_password.get_secret_value())
        device_id = token.device_id
        db.execute(delete(SessionToken).where(SessionToken.user_id == user.id))
        result = issue_session(db, user, device_id, settings, "password")
        db.commit()
        return result

    @app.post("/v1/auth/apple/challenge")
    def challenge(request: Request, db: Session = Depends(get_db)):
        app.state.rate_limiter.check(request, "apple_challenge")
        nonce = secret()
        value = LoginChallenge(nonce_hash=digest(nonce), expires_at=now() + timedelta(minutes=5))
        db.execute(delete(LoginChallenge).where(LoginChallenge.expires_at < now() - timedelta(hours=1)))
        db.add(value)
        db.commit()
        return {"challenge_id": value.id, "nonce": nonce, "expires_at": aware(value.expires_at)}

    @app.post("/v1/auth/apple")
    def apple_login(payload: AppleLogin, request: Request, db: Session = Depends(get_db)):
        app.state.rate_limiter.check(request, "apple_login", limit=10)
        value = db.scalar(select(LoginChallenge).where(LoginChallenge.id == str(payload.challenge_id)).with_for_update())
        if value is None or value.consumed or aware(value.expires_at) <= now():
            fail(401, "invalid_challenge", "Login challenge expired or was already used")
        claims = app.state.apple_verifier.verify(payload.identity_token)
        if not secrets.compare_digest(str(claims.get("nonce", "")), value.nonce_hash):
            fail(401, "invalid_nonce", "Apple identity verification failed")
        subject = claims.get("sub")
        if not isinstance(subject, str) or not 1 <= len(subject) <= 255:
            fail(401, "invalid_apple_token", "Apple identity verification failed")
        value.consumed = True
        user = db.scalar(select(User).where(User.apple_sub == subject, User.deleted.is_(False)))
        if user is None:
            user = User(apple_sub=subject)
            db.add(user)
            db.flush()
        device_id = str(payload.device_id)
        device = db.get(Device, device_id)
        if device and device.user_id != user.id:
            fail(409, "device_in_use", "This device identifier belongs to another account")
        if device is None:
            db.add(Device(id=device_id, user_id=user.id, name=payload.device_name))
            db.flush()
        result = issue_session(db, user, device_id, settings)
        db.commit()
        return result

    @app.get("/v1/me")
    def me(auth=Depends(session_auth)):
        return {"id": auth[0].id, "display_name": auth[0].display_name}

    @app.patch("/v1/me")
    def patch_me(payload: UserPatch, auth=Depends(session_auth), db: Session = Depends(get_db)):
        auth[0].display_name = payload.display_name.strip() or "ChronoGraph user"
        db.commit()
        return {"id": auth[0].id, "display_name": auth[0].display_name}

    @app.delete("/v1/auth/session", status_code=204)
    def logout(auth=Depends(session_auth), db: Session = Depends(get_db)):
        db.scalar(select(User).where(User.id == auth[0].id).with_for_update())
        if db.scalar(select(SessionToken.digest).where(SessionToken.digest == auth[1].digest)) is None:
            fail(401, "unauthorized", "Session has expired or was revoked")
        db.delete(auth[1])
        db.commit()

    @app.delete("/v1/auth/sessions", status_code=204)
    def logout_all(auth=Depends(session_auth), db: Session = Depends(get_db)):
        db.scalar(select(User).where(User.id == auth[0].id).with_for_update())
        if db.scalar(select(SessionToken.digest).where(SessionToken.digest == auth[1].digest)) is None:
            fail(401, "unauthorized", "Session has expired or was revoked")
        db.execute(delete(SessionToken).where(SessionToken.user_id == auth[0].id))
        db.commit()

    @app.post("/v1/auth/session/rotate")
    def rotate(auth=Depends(session_auth), db: Session = Depends(get_db)):
        user, token = auth
        db.scalar(select(User).where(User.id == user.id).with_for_update())
        if db.scalar(select(SessionToken.digest).where(SessionToken.digest == token.digest)) is None:
            fail(401, "unauthorized", "Session has expired or was revoked")
        result = issue_session(db, user, token.device_id, settings, token.auth_provider)
        db.delete(token)
        db.commit()
        return result

    @app.get("/v1/sources")
    def list_sources(auth=Depends(session_auth), db: Session = Depends(get_db)):
        return [source_json(s) for s in db.scalars(select(Source).where(Source.owner_id == auth[0].id).order_by(Source.name))]

    @app.post("/v1/sources", status_code=201)
    def create_source(payload: SourceCreate, auth=Depends(session_auth), db: Session = Depends(get_db)):
        user, session = auth
        if str(payload.device_id) != session.device_id:
            fail(403, "device_access_denied", "A source must use the current session's device")
        if db.get(Source, str(payload.id)) is not None:
            fail(409, "source_exists", "Source identifier already exists")
        if len(list(db.scalars(select(Source.id).where(Source.owner_id == user.id)))) >= 30:
            fail(422, "source_limit", "An account may have at most 30 sources")
        value = Source(id=str(payload.id), owner_id=user.id, device_id=session.device_id,
                       name=payload.name, upload_level=payload.upload_level.value)
        db.add(value)
        db.commit()
        return source_json(value)

    @app.patch("/v1/sources/{source_id}")
    def patch_source(source_id: UUID, payload: SourcePatch, auth=Depends(session_auth), db: Session = Depends(get_db)):
        value = owner_source(db, source_id, auth[0].id, lock=True)
        if payload.name is not None:
            value.name = payload.name
        if payload.upload_level is not None and payload.upload_level.value != value.upload_level:
            level = payload.upload_level.value
            if PRIVACY_RANK[level] < PRIVACY_RANK[value.upload_level]:
                values = {"location": None, "notes": None}
                if level == "opaque":
                    values["title"] = None
                db.execute(update(BusyEvent).where(BusyEvent.source_id == value.id).values(**values))
                # Existing links/grants cannot expose a wider projection after a reduction.
                for grant in db.scalars(select(Grant).where(Grant.source_id == value.id)):
                    if PRIVACY_RANK[grant.privacy] > PRIVACY_RANK[level]:
                        grant.privacy = level
                for link in db.scalars(select(ShareLink).where(ShareLink.source_id == value.id)):
                    if PRIVACY_RANK[link.privacy] > PRIVACY_RANK[level]:
                        link.privacy = level
            value.upload_level = level
            value.generation += 1
            value.snapshot_id = None
            value.snapshot_digest = None
        db.commit()
        return source_json(value)

    @app.delete("/v1/sources/{source_id}", status_code=204)
    def delete_source(source_id: UUID, auth=Depends(session_auth), db: Session = Depends(get_db)):
        value = owner_source(db, source_id, auth[0].id, lock=True)
        db.delete(value)
        db.commit()

    @app.put("/v1/sources/{source_id}/snapshot")
    def upload_snapshot(source_id: UUID, payload: Snapshot, auth=Depends(session_auth), db: Session = Depends(get_db)):
        value = owner_source(db, source_id, auth[0].id, lock=True)
        if value.device_id != auth[1].device_id:
            fail(403, "wrong_source_device", "Only the designated source device can upload")
        encoded = payload.model_dump_json()
        checksum = hashlib.sha256(encoded.encode()).hexdigest()
        if value.snapshot_id == str(payload.snapshot_id):
            if value.snapshot_digest != checksum:
                fail(409, "idempotency_conflict", "Snapshot ID was already used with different content")
            return source_json(value)
        if payload.expected_generation != value.generation:
            fail(409, "stale_generation", "Read the latest source generation before uploading")
        for event in payload.events:
            if value.upload_level == "opaque" and event.title is not None or value.upload_level != "full" and (event.location is not None or event.notes is not None):
                fail(422, "upload_scope_violation", "Event fields exceed this source's upload permission")
        # The server keeps only this source's latest complete, bounded snapshot.
        # Replacing the coverage must also remove historical rows outside that coverage.
        db.execute(delete(BusyEvent).where(BusyEvent.source_id == value.id))
        for event in payload.events:
            existing = db.get(BusyEvent, (value.id, str(event.id)))
            if existing is not None:
                db.delete(existing)
                db.flush()
            data = event.model_dump()
            data["id"] = str(event.id)
            data["series_id"] = str(event.series_id) if event.series_id else None
            db.add(BusyEvent(source_id=value.id, **data))
        value.generation += 1
        value.coverage_start, value.coverage_end = payload.window_start, payload.window_end
        value.last_synced_at = now()
        value.snapshot_id, value.snapshot_digest = str(payload.snapshot_id), checksum
        db.commit()
        return source_json(value)

    @app.get("/v1/sources/{source_id}/events")
    def source_events(source_id: UUID, start: datetime, end: datetime,
                      auth=Depends(session_auth), db: Session = Depends(get_db)):
        if start.tzinfo is None or end.tzinfo is None or not 0 < (end - start).total_seconds() <= 180 * 86400:
            fail(422, "invalid_range", "Use aware dates within a 180-day window")
        value = db.get(Source, str(source_id))
        grant = db.get(Grant, (str(source_id), auth[0].id))
        if value is None or value.owner_id != auth[0].id and grant is None:
            fail(404, "source_not_found", "Source is unavailable")
        if value.coverage_start is None or aware(start) < aware(value.coverage_start) or aware(end) > aware(value.coverage_end):
            fail(409, "missing_coverage", "This source does not cover the requested dates")
        privacy = value.upload_level if value.owner_id == auth[0].id else min((grant.privacy, value.upload_level), key=PRIVACY_RANK.get)
        output = []
        for event in db.scalars(select(BusyEvent).where(BusyEvent.source_id == value.id, BusyEvent.start < end,
                                                        BusyEvent.end > start).order_by(BusyEvent.start)):
            item = {"id": event.id, "start": aware(event.start), "end": aware(event.end), "is_all_day": event.is_all_day,
                    "timezone": event.timezone, "availability": event.availability}
            if privacy != "opaque":
                item["title"] = event.title
            if privacy == "full":
                item.update(location=event.location, notes=event.notes)
            output.append(item)
        return output

    def make_link(source_id, payload, kind, auth, db):
        source = owner_source(db, source_id, auth[0].id, lock=True)
        check_level(payload.privacy.value, source)
        raw = secret()
        link = ShareLink(digest=digest(raw), source_id=source.id, kind=kind, privacy=payload.privacy.value,
                         expires_at=now() + timedelta(days=payload.expires_in_days))
        db.add(link)
        db.commit()
        if kind == "pair":
            return {"id": link.id, "token": raw, "join_url": f"{settings.public_base_url}/join/{raw}", "expires_at": aware(link.expires_at)}
        return {"id": link.id, "url": f"{settings.public_base_url}/v1/feeds/{raw}.ics", "expires_at": aware(link.expires_at)}

    @app.post("/v1/sources/{source_id}/share-links", status_code=201)
    def create_share_link(source_id: UUID, payload: LinkInput, auth=Depends(session_auth), db: Session = Depends(get_db)):
        return make_link(source_id, payload, "pair", auth, db)

    @app.post("/v1/sources/{source_id}/feed-links", status_code=201)
    def create_feed_link(source_id: UUID, payload: LinkInput, auth=Depends(session_auth), db: Session = Depends(get_db)):
        return make_link(source_id, payload, "feed", auth, db)

    @app.get("/v1/sources/{source_id}/share-links")
    @app.get("/v1/sources/{source_id}/feed-links")
    def list_links(source_id: UUID, request: Request, auth=Depends(session_auth), db: Session = Depends(get_db)):
        source = owner_source(db, source_id, auth[0].id)
        kind = "feed" if request.url.path.endswith("feed-links") else "pair"
        return [{"id": link.id, "privacy": link.privacy, "expires_at": aware(link.expires_at),
                 "revoked": link.revoked, "redeemed_by": link.redeemed_by}
                for link in db.scalars(select(ShareLink).where(ShareLink.source_id == source.id, ShareLink.kind == kind))]

    @app.delete("/v1/share-links/{link_id}", status_code=204)
    @app.delete("/v1/feed-links/{link_id}", status_code=204)
    def revoke_link(link_id: UUID, auth=Depends(session_auth), db: Session = Depends(get_db)):
        value = db.get(ShareLink, str(link_id))
        if value is None:
            fail(404, "link_not_found", "Link is unavailable")
        owner_source(db, value.source_id, auth[0].id, lock=True)
        value.revoked = True
        db.commit()

    @app.post("/v1/share-links/redeem")
    def redeem(payload: Redeem, auth=Depends(session_auth), db: Session = Depends(get_db)):
        # Source -> link is the same locking order used by privacy changes/revocation.
        link = db.scalar(select(ShareLink).where(ShareLink.digest == digest(payload.token), ShareLink.kind == "pair"))
        if link is None:
            fail(404, "invalid_link", "Sharing link is invalid or expired")
        source = db.scalar(select(Source).where(Source.id == link.source_id).with_for_update().execution_options(populate_existing=True))
        link = db.scalar(select(ShareLink).where(ShareLink.id == link.id).with_for_update().execution_options(populate_existing=True))
        if link is None or link.revoked or aware(link.expires_at) <= now():
            fail(404, "invalid_link", "Sharing link is invalid or expired")
        if source is None:
            fail(404, "invalid_link", "Sharing link is invalid or expired")
        if source.owner_id == auth[0].id:
            fail(422, "own_share_link", "This is your own sharing link")
        grant = db.get(Grant, (source.id, auth[0].id))
        if link.redeemed_by is not None:
            if link.redeemed_by != auth[0].id or grant is None:
                fail(409, "link_already_used", "This sharing link was already used")
        else:
            link.redeemed_by = auth[0].id
            if grant is None:
                grant = Grant(source_id=source.id, viewer_id=auth[0].id, privacy=min((link.privacy, source.upload_level), key=PRIVACY_RANK.get))
                db.add(grant)
            else:
                grant.privacy = min((link.privacy, source.upload_level), key=PRIVACY_RANK.get)
        db.commit()
        return shared_json(db, source, grant.privacy)

    @app.get("/v1/shared-sources")
    def shared_sources(auth=Depends(session_auth), db: Session = Depends(get_db)):
        return [shared_json(db, source, grant.privacy) for source, grant in db.execute(
            select(Source, Grant).join(Grant, Source.id == Grant.source_id).where(Grant.viewer_id == auth[0].id))]

    @app.get("/v1/sources/{source_id}/grants")
    def list_grants(source_id: UUID, auth=Depends(session_auth), db: Session = Depends(get_db)):
        source = owner_source(db, source_id, auth[0].id)
        return [{"user_id": g.viewer_id, "privacy": g.privacy} for g in db.scalars(select(Grant).where(Grant.source_id == source.id))]

    @app.delete("/v1/sources/{source_id}/grants/{user_id}", status_code=204)
    def revoke_grant(source_id: UUID, user_id: UUID, auth=Depends(session_auth), db: Session = Depends(get_db)):
        source = owner_source(db, source_id, auth[0].id, lock=True)
        db.execute(delete(Grant).where(Grant.source_id == source.id, Grant.viewer_id == str(user_id)))
        db.commit()

    @app.get("/v1/feeds/{token}.ics")
    def feed(token: str, request: Request, db: Session = Depends(get_db)):
        app.state.rate_limiter.check(request, "feed", limit=120)
        if len(token) > 200:
            fail(404, "invalid_feed", "Calendar feed is unavailable")
        link = db.scalar(select(ShareLink).where(ShareLink.digest == digest(token), ShareLink.kind == "feed"))
        if link is None or link.revoked or aware(link.expires_at) <= now():
            fail(404, "invalid_feed", "Calendar feed is unavailable")
        source = db.get(Source, link.source_id)
        if source.coverage_start is None:
            fail(409, "missing_coverage", "Calendar has not been synchronized yet")
        events = list(db.scalars(select(BusyEvent).where(BusyEvent.source_id == source.id,
                            BusyEvent.start < source.coverage_end, BusyEvent.end > source.coverage_start).order_by(BusyEvent.start)))
        privacy = min((link.privacy, source.upload_level), key=PRIVACY_RANK.get)
        return Response(ics_document(events, source, privacy), media_type="text/calendar; charset=utf-8")

    @app.get("/join/{token}", response_class=PlainTextResponse)
    def join_landing(token: str):
        # No token reflection; private redemption always requires an authenticated POST.
        return "Open ChronoGraph → Cloud → Add shared calendar, then paste the sharing link or token."

    @app.post("/v1/availability/search")
    def availability(payload: Search, auth=Depends(session_auth), db: Session = Depends(get_db)):
        sources = accessible_sources(db, auth[0].id, payload.participants, payload.window_start, payload.window_end, settings)
        return {"timezone": payload.timezone, "checked_at": now(), "windows": search_windows(db, payload, sources),
                "sources": [{"id": s.id, "last_synced_at": aware(s.last_synced_at), "generation": s.generation} for s in sources]}

    @app.post("/v1/meetings", status_code=201)
    def create_meeting(payload: MeetingCreate, auth=Depends(session_auth), db: Session = Depends(get_db)):
        if payload.request_id is None:
            fail(422, "request_id_required", "A stable request_id is required when creating a meeting")
        # Serialize creations for this host; a lost response can safely be retried.
        db.scalar(select(User).where(User.id == auth[0].id).with_for_update())
        checksum = hashlib.sha256(payload.model_dump_json().encode()).hexdigest()
        existing = db.scalar(select(Meeting).where(Meeting.host_id == auth[0].id, Meeting.request_id == str(payload.request_id)))
        if existing is not None:
            if existing.request_digest != checksum:
                fail(409, "idempotency_conflict", "request_id was already used with different content")
            return meeting_json(db, existing)
        if payload.start <= now():
            fail(422, "past_meeting", "Choose a future meeting time")
        accessible_sources(db, auth[0].id, payload.participants, payload.start, payload.end, settings)
        value = Meeting(host_id=auth[0].id, request_id=str(payload.request_id), request_digest=checksum,
                        title=payload.title, start=payload.start, end=payload.end, timezone=payload.timezone)
        db.add(value)
        db.flush()
        for p in payload.participants:
            db.add(Participant(meeting_id=value.id, user_id=str(p.user_id), source_ids=[str(i) for i in p.source_ids],
                               response="accepted" if str(p.user_id) == auth[0].id else "pending"))
        db.commit()
        return meeting_json(db, value)

    @app.get("/v1/meetings")
    def list_meetings(auth=Depends(session_auth), db: Session = Depends(get_db)):
        values = db.scalars(select(Meeting).join(Participant).where(Participant.user_id == auth[0].id).order_by(Meeting.updated_at.desc()).limit(200))
        return [meeting_json(db, m) for m in values]

    @app.get("/v1/meetings/{meeting_id}")
    def get_meeting(meeting_id: UUID, auth=Depends(session_auth), db: Session = Depends(get_db)):
        return meeting_json(db, visible_meeting(db, meeting_id, auth[0].id))

    @app.patch("/v1/meetings/{meeting_id}")
    def patch_meeting(meeting_id: UUID, payload: MeetingPatch, auth=Depends(session_auth), db: Session = Depends(get_db)):
        value = visible_meeting(db, meeting_id, auth[0].id, lock=True)
        check_revision(value, payload.revision)
        if value.host_id != auth[0].id:
            fail(403, "host_required", "Only the host can change the proposal")
        if value.status == "cancelled":
            fail(409, "meeting_cancelled", "Create a new proposal for a cancelled meeting")
        if payload.start <= now():
            fail(422, "past_meeting", "Choose a future meeting time")
        accessible_sources(db, auth[0].id, payload.participants, payload.start, payload.end, settings)
        if value.status == "confirmed":
            projection_tasks(db, value, "delete")
        db.execute(delete(Reservation).where(Reservation.meeting_id == value.id))
        db.execute(delete(Participant).where(Participant.meeting_id == value.id))
        db.flush()
        value.revision += 1
        value.title, value.start, value.end, value.timezone = payload.title, payload.start, payload.end, payload.timezone
        value.status, value.updated_at = "proposed", now()
        for p in payload.participants:
            db.add(Participant(meeting_id=value.id, user_id=str(p.user_id), source_ids=[str(i) for i in p.source_ids],
                               response="accepted" if str(p.user_id) == auth[0].id else "pending"))
        db.commit()
        return meeting_json(db, value)

    @app.post("/v1/meetings/{meeting_id}/response")
    def respond(meeting_id: UUID, payload: MeetingResponse, auth=Depends(session_auth), db: Session = Depends(get_db)):
        value = visible_meeting(db, meeting_id, auth[0].id, lock=True)
        check_revision(value, payload.revision)
        if value.status != "proposed":
            fail(409, "meeting_not_proposed", "This meeting is not awaiting responses")
        person = db.get(Participant, (value.id, auth[0].id))
        if payload.response == "accepted":
            selection = PersonSelection(user_id=auth[0].id, source_ids=person.source_ids)
            sources = accessible_sources(db, auth[0].id, [selection], value.start, value.end, settings)
            if busy_ranges(db, sources, [auth[0].id], value.start, value.end, value.id):
                fail(409, "calendar_conflict", "This time conflicts with your current calendar")
        person.response = payload.response
        value.updated_at = now()
        db.commit()
        return meeting_json(db, value)

    @app.post("/v1/meetings/{meeting_id}/confirm")
    def confirm(meeting_id: UUID, payload: Version, auth=Depends(session_auth), db: Session = Depends(get_db)):
        value = visible_meeting(db, meeting_id, auth[0].id, lock=True)
        check_revision(value, payload.revision)
        if value.host_id != auth[0].id:
            fail(403, "host_required", "Only the host can confirm")
        if value.status == "confirmed":
            return meeting_json(db, value)
        if value.status != "proposed" or aware(value.start) <= now():
            fail(409, "meeting_not_proposed", "This meeting cannot be confirmed")
        participants = list(db.scalars(select(Participant).where(Participant.meeting_id == value.id)))
        if any(p.response != "accepted" for p in participants):
            fail(409, "responses_incomplete", "All participants must accept this proposal version")
        # Lock the same account rows in a deterministic order across different meetings.
        people = sorted(p.user_id for p in participants)
        list(db.scalars(select(User).where(User.id.in_(people)).order_by(User.id).with_for_update()))
        source_ids = sorted({s for p in participants for s in p.source_ids})
        list(db.scalars(select(Source).where(Source.id.in_(source_ids)).order_by(Source.id).with_for_update()
                        .execution_options(populate_existing=True)))
        selections = [PersonSelection(user_id=p.user_id, source_ids=p.source_ids) for p in participants]
        sources = accessible_sources(db, auth[0].id, selections, value.start, value.end, settings)
        if busy_ranges(db, sources, people, value.start, value.end, value.id):
            fail(409, "calendar_conflict", "A participant now has a conflicting event or confirmed meeting")
        for person in people:
            db.add(Reservation(meeting_id=value.id, user_id=person, start=value.start, end=value.end))
        value.status, value.updated_at = "confirmed", now()
        projection_tasks(db, value, "upsert")
        db.commit()
        return meeting_json(db, value)

    @app.post("/v1/meetings/{meeting_id}/cancel")
    def cancel(meeting_id: UUID, payload: Version, auth=Depends(session_auth), db: Session = Depends(get_db)):
        value = visible_meeting(db, meeting_id, auth[0].id, lock=True)
        check_revision(value, payload.revision)
        if value.host_id != auth[0].id:
            fail(403, "host_required", "Only the host can cancel")
        if value.status != "cancelled":
            if value.status == "confirmed":
                projection_tasks(db, value, "delete")
            value.status, value.updated_at = "cancelled", now()
            db.execute(delete(Reservation).where(Reservation.meeting_id == value.id))
        db.commit()
        return meeting_json(db, value)

    @app.get("/v1/device-tasks")
    def tasks(device_id: UUID, auth=Depends(session_auth), db: Session = Depends(get_db)):
        if str(device_id) != auth[1].device_id:
            fail(403, "device_access_denied", "Use the current session device")
        return [{"id": t.id, "meeting_id": t.meeting_id, "revision": t.revision, "action": t.action,
                 "payload": t.payload, "created_at": aware(t.created_at)} for t in db.scalars(select(DeviceTask).where(
                     DeviceTask.user_id == auth[0].id, DeviceTask.device_id == str(device_id), DeviceTask.completed.is_(False)
                 ).order_by(DeviceTask.created_at, DeviceTask.id).limit(200))]

    @app.post("/v1/device-tasks/{task_id}/ack", status_code=204)
    def acknowledge(task_id: UUID, auth=Depends(session_auth), db: Session = Depends(get_db)):
        task = db.get(DeviceTask, str(task_id))
        if task is None or task.user_id != auth[0].id or task.device_id != auth[1].device_id:
            fail(404, "task_not_found", "Task is unavailable")
        task.completed = True
        db.commit()

    @app.delete("/v1/me", status_code=204)
    def delete_account(auth=Depends(session_auth), db: Session = Depends(get_db)):
        user = auth[0]
        db.scalar(select(User).where(User.id == user.id).with_for_update())
        if db.scalar(select(SessionToken.digest).where(SessionToken.digest == auth[1].digest)) is None:
            fail(401, "unauthorized", "Session has expired or was revoked")
        # Retain only a pseudonymous actor stub for other people's coordination history.
        for value in db.scalars(select(Meeting).join(Participant).where(Participant.user_id == user.id,
                               Meeting.status != "cancelled").with_for_update()):
            if value.status == "confirmed":
                projection_tasks(db, value, "delete")
            value.status, value.updated_at = "cancelled", now()
            db.execute(delete(Reservation).where(Reservation.meeting_id == value.id))
        for person in db.scalars(select(Participant).where(Participant.user_id == user.id)):
            person.response = "declined"
            person.source_ids = []
        db.execute(delete(Reservation).where(Reservation.user_id == user.id))
        db.execute(delete(Grant).where(Grant.viewer_id == user.id))
        db.execute(delete(Source).where(Source.owner_id == user.id))
        db.execute(delete(SessionToken).where(SessionToken.user_id == user.id))
        db.execute(delete(PasswordCredential).where(PasswordCredential.user_id == user.id))
        db.execute(delete(DeviceTask).where(DeviceTask.user_id == user.id))
        db.execute(delete(Device).where(Device.user_id == user.id))
        user.apple_sub, user.display_name, user.deleted = "deleted:" + uid(), "Deleted account", True
        db.commit()

    return app


app = create_app()
