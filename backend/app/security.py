from datetime import timedelta
import hashlib
import secrets
import threading
import time
from fastapi import Depends, Header, HTTPException, Request
from sqlalchemy import select
from sqlalchemy.orm import Session
from argon2 import PasswordHasher, Type
from argon2.exceptions import VerifyMismatchError, VerificationError, InvalidHashError
import jwt
from .models import SessionToken, User, now


def digest(value: str):
    return hashlib.sha256(value.encode()).hexdigest()


def secret():
    return secrets.token_urlsafe(32)


def fail(status: int, code: str, message: str):
    raise HTTPException(status, detail={"code": code, "message": message})


def aware(value):
    from datetime import timezone
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def get_db(request: Request):
    with request.app.state.sessions() as db:
        yield db


def session_auth(request: Request, authorization: str | None = Header(default=None), db: Session = Depends(get_db)):
    if not authorization or not authorization.startswith("Bearer "):
        fail(401, "unauthorized", "A valid session is required")
    raw = authorization[7:]
    if not 20 <= len(raw) <= 200:
        fail(401, "unauthorized", "A valid session is required")
    token = db.get(SessionToken, digest(raw))
    if token is None or aware(token.expires_at) <= now():
        fail(401, "unauthorized", "Session has expired or was revoked")
    user = db.get(User, token.user_id)
    if user is None or user.deleted:
        fail(401, "unauthorized", "Account is unavailable")
    return user, token


class AppleVerifier:
    """Only Apple-hosted JWKS and RS256; no runtime bypass or caller-supplied key URL."""
    def __init__(self, audience: str):
        self.audience = audience
        self.keys = jwt.PyJWKClient("https://appleid.apple.com/auth/keys", cache_keys=True,
                                    lifespan=3600, timeout=5)

    def verify(self, identity_token: str):
        try:
            key = self.keys.get_signing_key_from_jwt(identity_token)
            return jwt.decode(identity_token, key.key, algorithms=["RS256"],
                              audience=self.audience, issuer="https://appleid.apple.com",
                              options={"require": ["exp", "iat", "iss", "aud", "sub", "nonce"]}, leeway=30)
        except (jwt.PyJWTError, ValueError, OSError):
            fail(401, "invalid_apple_token", "Apple identity verification failed")


class RateLimiter:
    """Small bounded per-process limiter; one API worker on the beta host."""
    def __init__(self):
        self.items = {}
        self.lock = threading.Lock()

    def check(self, request: Request, bucket: str, limit=20, seconds=60, identity: str | None = None):
        key = (identity if identity is not None else request.client.host if request.client else "unknown", bucket)
        instant = time.monotonic()
        with self.lock:
            if len(self.items) > 10_000:
                self.items = {k: v for k, v in self.items.items() if v[1] > instant}
                if len(self.items) > 10_000:
                    fail(429, "rate_limited", "Please wait before retrying")
            count, until = self.items.get(key, (0, instant + seconds))
            if until <= instant:
                count, until = 0, instant + seconds
            if count >= limit:
                fail(429, "rate_limited", "Please wait before retrying")
            self.items[key] = (count + 1, until)


class PasswordSecurity:
    """Explicit bounded Argon2id work for the small single-worker deployment."""
    def __init__(self):
        self.hasher = PasswordHasher(memory_cost=19_456, time_cost=2, parallelism=1,
                                     hash_len=32, salt_len=16, type=Type.ID)
        self.slots = threading.BoundedSemaphore(2)
        self.dummy_hash = self.hasher.hash(secret())

    def hash(self, password):
        if not self.slots.acquire(blocking=False):
            fail(429, "rate_limited", "Please wait before retrying")
        try:
            return self.hasher.hash(password)
        finally:
            self.slots.release()

    def verify(self, encoded, password):
        if not self.slots.acquire(blocking=False):
            fail(429, "rate_limited", "Please wait before retrying")
        try:
            try:
                self.hasher.verify(encoded or self.dummy_hash, password)
                return encoded is not None
            except (VerifyMismatchError, VerificationError, InvalidHashError):
                return False
        finally:
            self.slots.release()


def issue_session(db, user, device_id, settings, auth_provider="apple"):
    raw = secret()
    token = SessionToken(digest=digest(raw), user_id=user.id, device_id=device_id,
                         expires_at=now() + timedelta(days=settings.session_ttl_days), auth_provider=auth_provider)
    db.add(token)
    db.flush()
    return {"access_token": raw, "token_type": "bearer", "expires_at": aware(token.expires_at),
            "user": {"id": user.id, "display_name": user.display_name}, "device_id": device_id,
            "auth_provider": auth_provider}
