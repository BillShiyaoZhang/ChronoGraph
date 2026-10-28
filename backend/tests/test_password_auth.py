from datetime import timedelta
from uuid import uuid4
import pytest
from sqlalchemy import select
from app.models import PasswordCredential, RegistrationInvite, SessionToken, User, now
from app.security import digest, secret
from conftest import login, source, grant


PASSWORD = "test correct horse battery"


def invite(api, *, days=7, uses=1, revoked=False):
    raw = secret()
    with api[1].state.sessions() as db:
        db.add(RegistrationInvite(digest=digest(raw), expires_at=now() + timedelta(days=days),
                                  max_uses=uses, uses=0, revoked=revoked))
        db.commit()
    return raw


def register(api, username="local_person", **changes):
    body = {"username": username, "password": PASSWORD, "invite_code": invite(api),
            "device_id": str(uuid4()), "device_name": "Test password iPhone"}
    body.update(changes)
    return api[0].post("/v1/auth/password/register", json=body)


def password_login(api, username="local_person", password=PASSWORD, device_id=None):
    return api[0].post("/v1/auth/password/login", json={"username": username, "password": password,
                            "device_id": device_id or str(uuid4()), "device_name": "Other iPhone"})


def authenticated(response):
    assert response.status_code in {200, 201}, response.text
    value = response.json()
    value["headers"] = {"Authorization": "Bearer " + value["access_token"]}
    return value


def test_password_account_uses_existing_cloud_contract_and_no_plaintext(api):
    assert api[0].get("/v1/auth/options").json() == {
        "password_enabled": True, "registration_mode": "invite", "password_min_length": 12, "password_max_length": 128}
    person = authenticated(register(api, "  Mixed_Case.123  "))
    assert person["auth_provider"] == "password"
    assert person["user"]["display_name"] == "mixed_case.123"
    assert api[0].get("/v1/me", headers=person["headers"]).json() == person["user"]
    calendar, _ = source(api, person)
    assert api[0].get("/v1/sources", headers=person["headers"]).json()[0]["id"] == calendar["id"]
    with api[1].state.sessions() as db:
        value = db.get(PasswordCredential, person["user"]["id"])
        assert value.username == "mixed_case.123"
        assert value.password_hash.startswith("$argon2id$")
        assert PASSWORD not in value.password_hash
        assert db.get(User, value.user_id).apple_sub is None
        assert db.get(SessionToken, digest(person["access_token"])).auth_provider == "password"
        assert db.get(SessionToken, person["access_token"]) is None
    another = authenticated(password_login(api, "MIXED_CASE.123", device_id=person["device_id"]))
    assert another["user"] == person["user"]


def test_password_login_generic_error_and_raw_password_spaces(api):
    raw = "  preserve these spaces  "
    authenticated(register(api, password=raw))
    wrong = password_login(api, password=raw.strip())
    absent = password_login(api, "missing_person", password=raw)
    assert wrong.status_code == absent.status_code == 401
    assert wrong.json() == absent.json()
    assert password_login(api, password=raw).status_code == 200


@pytest.mark.parametrize("username", ["ab", "a" * 33, "用户名", "bad@name", "a\nb"])
def test_username_boundaries(api, username):
    assert register(api, username).status_code == 422


@pytest.mark.parametrize("password", ["short", "p" * 129, "\ud800" * 12])
def test_password_validation_does_not_echo_secret(api, password):
    # Surrogates are sent as escaped JSON, without trying to UTF-8 encode invalid text.
    import json
    response = api[0].post("/v1/auth/password/register", content=json.dumps({"username": "valid_person",
        "password": password, "invite_code": invite(api), "device_id": str(uuid4())}), headers={"Content-Type": "application/json"})
    assert response.status_code == 422
    assert password not in response.text
    assert "input" not in response.json()["detail"]


def test_unicode_password_boundary_and_display_name(api):
    value = authenticated(register(api, password="🔐" * 128, display_name="  A person  "))
    assert value["user"]["display_name"] == "A person"
    assert password_login(api, password="🔐" * 128).status_code == 200


@pytest.mark.parametrize("kind", ["expired", "revoked", "invalid"])
def test_registration_requires_valid_invite(api, kind):
    raw = invite(api, days=-1 if kind == "expired" else 7, revoked=kind == "revoked")
    if kind == "invalid":
        raw = secret()
    response = register(api, invite_code=raw)
    assert response.status_code == 401
    assert response.json()["detail"]["code"] == "invalid_invite"
    with api[1].state.sessions() as db:
        assert list(db.scalars(select(PasswordCredential))) == []


def test_single_use_invite_and_failed_conflict_do_not_consume(api):
    raw = invite(api)
    first = authenticated(register(api, invite_code=raw))
    assert register(api, "second_person", invite_code=raw).status_code == 401
    reusable = invite(api)
    assert register(api, "LOCAL_PERSON", invite_code=reusable).status_code == 409
    assert register(api, "other_person", invite_code=reusable, device_id=first["device_id"]).status_code == 409
    assert register(api, "other_person", invite_code=reusable).status_code == 201
    with api[1].state.sessions() as db:
        assert db.scalar(select(RegistrationInvite).where(RegistrationInvite.digest == digest(reusable))).uses == 1


def test_login_cannot_claim_another_account_device(api):
    first = authenticated(register(api))
    other = authenticated(register(api, "other_person"))
    response = password_login(api, "other_person", device_id=first["device_id"])
    assert response.status_code == 409
    assert api[0].get("/v1/me", headers=other["headers"]).status_code == 200


def test_rotate_change_and_logout_revoke_sessions(api):
    first = authenticated(register(api))
    second = authenticated(password_login(api))
    rotated = authenticated(api[0].post("/v1/auth/session/rotate", headers=first["headers"]))
    assert rotated["auth_provider"] == "password"
    assert api[0].get("/v1/me", headers=first["headers"]).status_code == 401
    wrong = api[0].post("/v1/auth/password/change", headers=rotated["headers"], json={
        "current_password": "wrong password long enough", "new_password": "another long password"})
    assert wrong.status_code == 403
    assert api[0].get("/v1/me", headers=rotated["headers"]).status_code == 200
    changed = authenticated(api[0].post("/v1/auth/password/change", headers=rotated["headers"], json={
        "current_password": PASSWORD, "new_password": "another long password"}))
    assert changed["auth_provider"] == "password"
    assert changed["device_id"] == first["device_id"]
    for person in (rotated, second):
        assert api[0].get("/v1/me", headers=person["headers"]).status_code == 401
    assert password_login(api).status_code == 401
    assert password_login(api, password="another long password").status_code == 200
    assert api[0].delete("/v1/auth/sessions", headers=changed["headers"]).status_code == 204
    assert api[0].get("/v1/me", headers=changed["headers"]).status_code == 401


def test_deleted_password_identity_cannot_recover_old_grants(api):
    person = authenticated(register(api))
    owner = login(api)
    calendar, _ = source(api, owner)
    grant(api, owner, calendar, person)
    assert api[0].delete("/v1/me", headers=person["headers"]).status_code == 204
    assert password_login(api).status_code == 401
    replacement = authenticated(register(api, device_id=person["device_id"]))
    assert replacement["user"]["id"] != person["user"]["id"]
    assert api[0].get("/v1/shared-sources", headers=replacement["headers"]).json() == []
    with api[1].state.sessions() as db:
        assert db.get(PasswordCredential, person["user"]["id"]) is None
        assert db.get(User, person["user"]["id"]).deleted


def test_password_login_is_rate_limited_before_hash(api, monkeypatch):
    calls = []
    original = api[1].state.password_security.verify
    def tracked(encoded, raw):
        calls.append(True)
        return original(encoded, raw)
    monkeypatch.setattr(api[1].state.password_security, "verify", tracked)
    statuses = [password_login(api, "missing_person").status_code for _ in range(25)]
    assert statuses[0] == 401
    assert 429 in statuses
    assert len(calls) < len(statuses)


def test_hash_work_has_a_bounded_concurrency_limit(api):
    password_security = api[1].state.password_security
    assert password_security.slots.acquire(blocking=False)
    assert password_security.slots.acquire(blocking=False)
    try:
        assert password_login(api, "missing_person").status_code == 429
    finally:
        password_security.slots.release()
        password_security.slots.release()


def test_admin_invite_creation_and_revocation_use_only_digests(api, monkeypatch, capsys):
    from app import accounts
    monkeypatch.setattr(accounts, "make_engine", lambda _: api[1].state.engine)
    accounts.main(["create-invite", "--days", "7", "--uses", "2"])
    raw = capsys.readouterr().out.strip()
    assert len(raw) >= 32
    with api[1].state.sessions() as db:
        stored = db.scalar(select(RegistrationInvite))
        assert stored.digest == digest(raw)
        assert raw not in stored.digest
        assert stored.max_uses == 2
        invitation_id = stored.id
    assert register(api, invite_code=raw).status_code == 201
    accounts.main(["revoke-invites", "--id", invitation_id])
    assert raw not in capsys.readouterr().out
    assert register(api, "other_person", invite_code=raw).status_code == 401


def test_admin_password_reset_is_private_and_revokes_all_sessions(api, monkeypatch, capsys):
    from app import accounts
    person = authenticated(register(api))
    another = authenticated(password_login(api))
    replacement = "Private synthetic admin password"
    monkeypatch.setattr(accounts, "make_engine", lambda _: api[1].state.engine)
    monkeypatch.setattr(accounts, "getpass", lambda _: replacement)
    accounts.main(["reset-password", "LOCAL_PERSON"])
    assert replacement not in capsys.readouterr().out
    for old in (person, another):
        assert api[0].get("/v1/me", headers=old["headers"]).status_code == 401
    assert password_login(api).status_code == 401
    assert password_login(api, password=replacement).status_code == 200


def test_admin_password_reset_refuses_echoed_input(api, monkeypatch):
    from app import accounts
    from getpass import GetPassWarning
    import warnings
    monkeypatch.setattr(accounts, "make_engine", lambda _: api[1].state.engine)
    def unsafe_getpass(_):
        warnings.warn("Password input may be echoed", GetPassWarning)
        pytest.fail("getpass fallback must stop before reading a password")
    monkeypatch.setattr(accounts, "getpass", unsafe_getpass)
    with pytest.raises(SystemExit, match="private interactive terminal"):
        accounts.main(["reset-password", "local_person"])
