from datetime import datetime, timezone, timedelta
from uuid import uuid4
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from sqlalchemy import select
from app.models import SessionToken, User
from conftest import login, signed_token, source


def test_apple_login_replay_and_hashed_revocable_sessions(api):
    client, app, key = api
    challenge = client.post("/v1/auth/apple/challenge").json()
    token = signed_token(key, challenge["nonce"])
    payload = {"challenge_id": challenge["challenge_id"], "identity_token": token, "device_id": str(uuid4())}
    response = client.post("/v1/auth/apple", json=payload)
    assert response.status_code == 200
    data = response.json()
    assert client.post("/v1/auth/apple", json=payload).status_code == 401
    headers = {"Authorization": "Bearer " + data["access_token"]}
    assert client.get("/v1/me", headers=headers).json()["id"] == data["user"]["id"]
    with app.state.sessions() as db:
        assert db.scalars(select(SessionToken)).first().digest != data["access_token"]
    rotated = client.post("/v1/auth/session/rotate", headers=headers)
    assert rotated.status_code == 200
    assert client.get("/v1/me", headers=headers).status_code == 401
    replacement = {"Authorization": "Bearer " + rotated.json()["access_token"]}
    assert client.delete("/v1/auth/session", headers=replacement).status_code == 204
    assert client.get("/v1/me", headers=replacement).status_code == 401


@pytest.mark.parametrize("overrides", [{"aud": "other.app"}, {"iss": "https://evil.test"},
    {"nonce": "wrong"}, {"exp": datetime(2000, 1, 1, tzinfo=timezone.utc)}])
def test_apple_claim_validation(api, overrides):
    client, _, key = api
    challenge = client.post("/v1/auth/apple/challenge").json()
    token = signed_token(key, challenge["nonce"], **overrides)
    response = client.post("/v1/auth/apple", json={"challenge_id": challenge["challenge_id"],
                           "identity_token": token, "device_id": str(uuid4())})
    assert response.status_code == 401
    assert token not in response.text


def test_forged_signature_and_missing_auth_fail_closed(api):
    client, _, _ = api
    challenge = client.post("/v1/auth/apple/challenge").json()
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    token = signed_token(key, challenge["nonce"])
    r = client.post("/v1/auth/apple", json={"challenge_id": challenge["challenge_id"],
                    "identity_token": token, "device_id": str(uuid4())})
    assert r.status_code == 401
    assert client.get("/v1/sources").status_code == 401
    assert client.get("/v1/me", headers={"Authorization": "Bearer fake-test-token-long-enough"}).status_code == 401


def test_auth_challenge_is_rate_limited(api):
    client, _, _ = api
    for _ in range(20):
        assert client.post("/v1/auth/apple/challenge").status_code == 200
    assert client.post("/v1/auth/apple/challenge").status_code == 429


def test_device_binding_cannot_be_claimed_by_another_user(api):
    first = login(api, "first")
    client, _, key = api
    c = client.post("/v1/auth/apple/challenge").json()
    r = client.post("/v1/auth/apple", json={"challenge_id": c["challenge_id"],
           "identity_token": signed_token(key, c["nonce"], "other"), "device_id": first["device_id"]})
    assert r.status_code == 409


def test_validation_does_not_echo_secret_inputs(api):
    client, _, _ = api
    r = client.post("/v1/auth/apple", json={"identity_token": "SECRET", "private": "PRIVATE NOTE"})
    assert r.status_code == 422
    assert "SECRET" not in r.text and "PRIVATE NOTE" not in r.text


def test_profile_update_delete_and_sign_in_again(api):
    client, app, _ = api
    user = login(api, "first")
    src, _ = source(api, user)
    r = client.patch("/v1/me", headers=user["headers"], json={"display_name": "Alex"})
    assert r.json()["display_name"] == "Alex"
    assert client.delete("/v1/me", headers=user["headers"]).status_code == 204
    assert client.get("/v1/me", headers=user["headers"]).status_code == 401
    again = login(api, "first", device_id=user["device_id"])
    assert again["user"]["id"] != user["user"]["id"]
    assert client.get("/v1/sources", headers=again["headers"]).json() == []
    with app.state.sessions() as db:
        deleted = db.get(User, user["user"]["id"])
        assert deleted.deleted and deleted.apple_sub != "first"


def test_health_and_no_store(api):
    client, _, _ = api
    assert client.get("/healthz").json() == {"status": "ok"}
    assert client.get("/health/ready").status_code == 200
    assert client.get("/").headers["cache-control"] == "no-store"
