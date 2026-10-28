from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from uuid import uuid4
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from app.config import Settings
from app.database import Base, make_engine
from app.main import create_app
from app.security import digest


@pytest.fixture
def api():
    engine = make_engine("sqlite+pysqlite:///:memory:")
    Base.metadata.create_all(engine)
    app = create_app(Settings(database_url="sqlite+pysqlite:///:memory:", public_base_url="https://example.com/chronograph"), engine)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    class Keys:
        def get_signing_key_from_jwt(self, token):
            return SimpleNamespace(key=key.public_key())
    app.state.apple_verifier.keys = Keys()
    with TestClient(app) as client:
        yield client, app, key
    engine.dispose()


def signed_token(key, raw_nonce, subject="apple-test-person", **overrides):
    instant = datetime.now(timezone.utc)
    claims = {"sub": subject, "iss": "https://appleid.apple.com", "aud": "com.shiyao-zhang.ChronoGraph",
              "exp": instant + timedelta(minutes=5), "iat": instant, "nonce": digest(raw_nonce)}
    claims.update(overrides)
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "test-key"})


def login(api, subject="apple-person", device_id=None):
    client, app, key = api
    challenge = client.post("/v1/auth/apple/challenge").json()
    token = signed_token(key, challenge["nonce"], subject)
    response = client.post("/v1/auth/apple", json={"challenge_id": challenge["challenge_id"], "identity_token": token,
                          "device_id": device_id or str(uuid4()), "device_name": "Test iPhone"})
    assert response.status_code == 200, response.text
    value = response.json()
    value["headers"] = {"Authorization": "Bearer " + value["access_token"]}
    return value


def window():
    day = (datetime.now(timezone.utc) + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return day, day + timedelta(days=3)


def source(api, user, level="opaque", events=None):
    client, _, _ = api
    response = client.post("/v1/sources", headers=user["headers"], json={"id": str(uuid4()), "name": "My calendar",
                           "device_id": user["device_id"], "upload_level": level})
    assert response.status_code == 201, response.text
    value = response.json()
    a, b = window()
    payload = {"snapshot_id": str(uuid4()), "expected_generation": 0, "window_start": a.isoformat(),
               "window_end": b.isoformat(), "events": events or []}
    response = client.put(f"/v1/sources/{value['id']}/snapshot", headers=user["headers"], json=payload)
    assert response.status_code == 200, response.text
    return response.json(), payload


def grant(api, owner, calendar, viewer, privacy="opaque"):
    client, _, _ = api
    r = client.post(f"/v1/sources/{calendar['id']}/share-links", headers=owner["headers"], json={"privacy": privacy})
    assert r.status_code == 201, r.text
    link = r.json()
    r = client.post("/v1/share-links/redeem", headers=viewer["headers"], json={"token": link["token"]})
    assert r.status_code == 200, r.text
    return link


def pair(api, level="opaque"):
    a, b = login(api, "person-a"), login(api, "person-b")
    sa, _ = source(api, a, level)
    sb, _ = source(api, b, level)
    grant(api, a, sa, b, level)
    grant(api, b, sb, a, level)
    people = [{"user_id": a["user"]["id"], "source_ids": [sa["id"]]},
              {"user_id": b["user"]["id"], "source_ids": [sb["id"]]}]
    return a, b, sa, sb, people
