"""Run against a NEW disposable PostgreSQL DB named chronograph_verify_* only.

VERIFY_DATABASE_URL=postgresql+psycopg://.../chronograph_verify_... python scripts/verify_postgres.py
Uses synthetic ORM setup, never a production login bypass or real account data.
"""
import concurrent.futures
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sys
import threading
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sqlalchemy import select, inspect, text
from sqlalchemy.engine import make_url

url = os.environ.get("VERIFY_DATABASE_URL", "")
if not url or not make_url(url).database.startswith("chronograph_verify_") or not make_url(url).drivername.startswith("postgresql"):
    raise SystemExit("Refusing: VERIFY_DATABASE_URL must select a NEW disposable PostgreSQL database named chronograph_verify_*.")
os.environ["DATABASE_URL"] = url

from alembic import command
from alembic.config import Config
from alembic.autogenerate import compare_metadata
from alembic.migration import MigrationContext
from fastapi.testclient import TestClient
from app.config import Settings
from app.database import Base, make_engine
from app.main import create_app
from app.models import User, Device, Source, Grant, Meeting, Participant, Reservation, DeviceTask, RegistrationInvite, PasswordCredential, SessionToken
from app.security import issue_session, digest, secret


def run():
    engine = make_engine(url)
    if inspect(engine).get_table_names():
        raise SystemExit("Refusing: verification database is not empty; use a new database.")
    config = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
    config.set_main_option("script_location", str(Path(__file__).resolve().parents[1] / "migrations"))
    command.upgrade(config, "0380e9c4211c")
    legacy_user, legacy_device, legacy_source, legacy_event = [str(uuid4()) for _ in range(4)]
    legacy_instant = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text("INSERT INTO users (id,apple_sub,display_name,deleted,created_at) VALUES (:id,'legacy-apple','Legacy',false,:instant)"), {"id": legacy_user, "instant": legacy_instant})
        connection.execute(text("INSERT INTO devices (id,user_id,name,created_at) VALUES (:id,:user,'Legacy iPhone',:instant)"), {"id": legacy_device, "user": legacy_user, "instant": legacy_instant})
        connection.execute(text("INSERT INTO sessions (digest,user_id,device_id,expires_at) VALUES (:digest,:user,:device,:instant)"), {"digest": "a" * 64, "user": legacy_user, "device": legacy_device, "instant": legacy_instant})
        connection.execute(text("INSERT INTO sources (id,owner_id,device_id,name,upload_level,generation) VALUES (:id,:user,:device,'Legacy calendar','opaque',0)"), {"id": legacy_source, "user": legacy_user, "device": legacy_device})
        connection.execute(text("INSERT INTO busy_events (source_id,id,start,\"end\",is_all_day,timezone,availability) VALUES (:source,:id,:start,:end,false,'UTC','busy')"),
                           {"source": legacy_source, "id": legacy_event, "start": legacy_instant, "end": legacy_instant + timedelta(hours=1)})
    command.upgrade(config, "head")
    command.upgrade(config, "head")
    with engine.connect() as connection:
        assert compare_metadata(MigrationContext.configure(connection), Base.metadata) == [], "migration/metadata mismatch"
        assert connection.execute(text("SELECT apple_sub FROM users WHERE id=:id"), {"id": legacy_user}).scalar_one() == "legacy-apple"
        assert connection.execute(text("SELECT auth_provider FROM sessions WHERE user_id=:id"), {"id": legacy_user}).scalar_one() == "apple"
        assert connection.execute(text("SELECT owner_id FROM sources WHERE id=:id"), {"id": legacy_source}).scalar_one() == legacy_user
        assert connection.execute(text("SELECT visibility FROM busy_events WHERE id=:id"), {"id": legacy_event}).scalar_one() == "opaque"
    settings = Settings(database_url=url, public_base_url="https://example.invalid")
    app = create_app(settings, engine)
    instant = datetime.now(timezone.utc)
    day = (instant + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    people = []
    with app.state.sessions() as db:
        for index in range(3):
            user = User(apple_sub=f"synthetic-postgres-{uuid4()}")
            db.add(user)
            db.flush()
            device = Device(id=str(uuid4()), user_id=user.id, name="Synthetic verification")
            db.add(device)
            db.flush()
            source = Source(id=str(uuid4()), owner_id=user.id, device_id=device.id, name="Synthetic calendar",
                            upload_level="full", generation=1, coverage_start=day,
                            coverage_end=day + timedelta(days=3), last_synced_at=instant)
            db.add(source)
            session = issue_session(db, user, device.id, settings)
            people.append({"id": user.id, "device": device.id, "source": source.id,
                           "headers": {"Authorization": "Bearer " + session["access_token"]}})
        for host in people[:2]:
            db.add(Grant(source_id=people[2]["source"], viewer_id=host["id"], privacy="opaque"))
        db.flush()
        meeting_ids = []
        for host in people[:2]:
            meeting = Meeting(host_id=host["id"], request_id=str(uuid4()), request_digest="a" * 64,
                              title="Synthetic concurrency check", start=day + timedelta(hours=12),
                              end=day + timedelta(hours=13), timezone="UTC")
            db.add(meeting)
            db.flush()
            for person in (host, people[2]):
                db.add(Participant(meeting_id=meeting.id, user_id=person["id"], source_ids=[person["source"]], response="accepted"))
            meeting_ids.append(meeting.id)
        db.commit()

    # One logical source combines local calendars/occurrences without sending their IDs.
    mixed_ids = [str(uuid4()) for _ in range(3)]
    mixed = [{"id": identity, "start": (day + timedelta(hours=9 + index)).isoformat(),
              "end": (day + timedelta(hours=10 + index)).isoformat(), "visibility": level}
             for index, (identity, level) in enumerate(zip(mixed_ids, ["opaque", "partial", "full"]))]
    mixed[1]["title"] = "Synthetic title only"
    mixed[2].update(title="Synthetic full title", location="Synthetic private location", notes="Synthetic private notes")
    with TestClient(app) as client:
        snapshot = {"snapshot_id": str(uuid4()), "expected_generation": 1, "window_start": day.isoformat(),
                    "window_end": (day + timedelta(days=3)).isoformat(), "events": mixed}
        source_path = f"/v1/sources/{people[0]['source']}"
        uploaded = client.put(source_path + "/snapshot", headers=people[0]["headers"], json=snapshot)
        assert uploaded.status_code == 200, "mixed PostgreSQL snapshot failed"
        assert client.put(source_path + "/snapshot", headers=people[0]["headers"], json=snapshot).json()["generation"] == 2
        changed = {**snapshot, "events": [{**mixed[0], "visibility": "partial"}, *mixed[1:]]}
        assert client.put(source_path + "/snapshot", headers=people[0]["headers"], json=changed).status_code == 409
        values = client.get(source_path + "/events", headers=people[0]["headers"],
                            params={"start": day.isoformat(), "end": (day + timedelta(days=3)).isoformat()}).json()
        projected = {event["id"]: event for event in values}
        assert projected[mixed_ids[0]]["visibility"] == "opaque" and "title" not in projected[mixed_ids[0]]
        assert projected[mixed_ids[1]]["visibility"] == "partial" and "notes" not in projected[mixed_ids[1]]
        assert projected[mixed_ids[2]]["notes"] == "Synthetic private notes"
        feed = client.post(source_path + "/feed-links", headers=people[0]["headers"], json={"privacy": "full"}).json()
        feed_document = client.get("/v1/feeds/" + feed["url"].split("/")[-1]).text
        blocks = feed_document.split("BEGIN:VEVENT\r\n")[1:]
        assert "SUMMARY:busy\r\n" in blocks[0] and "LOCATION:" not in blocks[0]
        assert "SUMMARY:Synthetic title only\r\n" in blocks[1] and "DESCRIPTION:" not in blocks[1]
        assert "DESCRIPTION:Synthetic private notes\r\n" in blocks[2]

    def race(functions):
        barrier = threading.Barrier(len(functions))
        def invoke(function):
            with TestClient(app) as client:
                barrier.wait(timeout=10)
                return function(client)
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(functions)) as executor:
            return list(executor.map(invoke, functions))

    responses = race([lambda c, i=i: c.post(f"/v1/meetings/{meeting_ids[i]}/confirm", headers=people[i]["headers"], json={"revision": 1}) for i in range(2)])
    assert sorted(r.status_code for r in responses) == [200, 409], "concurrent confirmations did not serialize"
    with app.state.sessions() as db:
        assert len(list(db.scalars(select(Reservation).where(Reservation.user_id == people[2]["id"])))) == 1
        assert len(list(db.scalars(select(DeviceTask)))) == 2

    responses = race([lambda c: c.put(f"/v1/sources/{people[2]['source']}/snapshot", headers=people[2]["headers"],
                        json={"snapshot_id": str(uuid4()), "expected_generation": 1,
                              "window_start": day.isoformat(), "window_end": (day + timedelta(days=3)).isoformat(), "events": []}) for _ in range(2)])
    assert sorted(r.status_code for r in responses) == [200, 409], "concurrent source snapshots did not enforce generation"

    with TestClient(app) as client:
        link = client.post(f"/v1/sources/{people[0]['source']}/share-links", headers=people[0]["headers"], json={"privacy": "full"}).json()
    responses = race([
        lambda c: c.patch(f"/v1/sources/{people[0]['source']}", headers=people[0]["headers"], json={"upload_level": "opaque"}),
        lambda c: c.post("/v1/share-links/redeem", headers=people[2]["headers"], json={"token": link["token"]}),
    ])
    assert all(r.status_code == 200 for r in responses), "concurrent grant/privacy update failed"
    with app.state.sessions() as db:
        assert db.get(Grant, (people[0]["source"], people[2]["id"])).privacy == "opaque", "grant escaped privacy reduction"
        from app.models import BusyEvent
        rows = list(db.scalars(select(BusyEvent).where(BusyEvent.source_id == people[0]["source"])))
        assert len(rows) == 3 and all(event.visibility == "opaque" for event in rows)
        assert all(event.title is None and event.location is None and event.notes is None for event in rows)

    # Receiver deletion shares the source lock with owner mutations and redemption.
    owner, receiver = people[0], people[2]
    unsubscribe = f"/v1/shared-sources/{owner['source']}"
    responses = race([
        lambda c: c.delete(unsubscribe, headers=receiver["headers"]),
        lambda c: c.post("/v1/share-links/redeem", headers=receiver["headers"], json={"token": link["token"]}),
    ])
    assert responses[0].status_code == 204 and responses[1].status_code in {200, 409}, "unsubscribe/consumed redemption race failed"
    with app.state.sessions() as db:
        assert db.get(Grant, (owner["source"], receiver["id"])) is None, "consumed link restored a removed grant"
        assert db.get(Source, owner["source"]) is not None
        assert len(list(db.scalars(select(Reservation)))) == 2
        assert len(list(db.scalars(select(DeviceTask)))) == 2
    with TestClient(app) as client:
        fresh = client.post(f"/v1/sources/{owner['source']}/share-links", headers=owner["headers"], json={}).json()
    responses = race([
        lambda c: c.delete(unsubscribe, headers=receiver["headers"]),
        lambda c: c.post("/v1/share-links/redeem", headers=receiver["headers"], json={"token": fresh["token"]}),
    ])
    assert [r.status_code for r in responses] == [204, 200], "unsubscribe/fresh explicit redemption did not serialize"
    # Either transaction order is valid; another idempotent unsubscribe must remove the result.
    with TestClient(app) as client:
        assert client.delete(unsubscribe, headers=receiver["headers"]).status_code == 204
        assert client.post("/v1/share-links/redeem", headers=receiver["headers"], json={"token": fresh["token"]}).status_code == 409
        renewed = client.post(f"/v1/sources/{owner['source']}/share-links", headers=owner["headers"], json={}).json()
        assert client.post("/v1/share-links/redeem", headers=receiver["headers"], json={"token": renewed["token"]}).status_code == 200
    responses = race([
        lambda c: c.delete(unsubscribe, headers=receiver["headers"]),
        lambda c: c.delete(f"/v1/sources/{owner['source']}/grants/{receiver['id']}", headers=owner["headers"]),
        lambda c: c.delete(f"/v1/share-links/{renewed['id']}", headers=owner["headers"]),
    ])
    assert all(r.status_code == 204 for r in responses), "receiver/owner grant/link revocation race failed"
    with TestClient(app) as client:
        assert client.post("/v1/share-links/redeem", headers=receiver["headers"], json={"token": renewed["token"]}).status_code == 404
        assert client.get(f"/v1/sources/{owner['source']}/events", headers=receiver["headers"],
                          params={"start": day.isoformat(), "end": (day + timedelta(days=3)).isoformat()}).status_code == 404

    # Real PostgreSQL conditional UPDATE/unique constraints, not SQLite's coarse lock.
    invite_secret = secret()
    with app.state.sessions() as db:
        invitation = RegistrationInvite(digest=digest(invite_secret), expires_at=instant + timedelta(days=1),
                                        max_uses=1, uses=0, revoked=False)
        db.add(invitation)
        db.commit()
        invitation_id = invitation.id
    password = "Synthetic password verification"
    registration_payloads = [{"username": f"race_person_{i}", "password": password,
        "invite_code": invite_secret, "device_id": str(uuid4())} for i in range(2)]
    responses = race([lambda c, body=body: c.post("/v1/auth/password/register", json=body) for body in registration_payloads])
    assert sorted(r.status_code for r in responses) == [201, 401], "single-use invite was consumed more than once"
    winner_index = next(i for i, response in enumerate(responses) if response.status_code == 201)
    registered = responses[winner_index].json()
    username = registration_payloads[winner_index]["username"]
    with app.state.sessions() as db:
        assert db.get(RegistrationInvite, invitation_id).uses == 1
        assert len(list(db.scalars(select(PasswordCredential)))) == 1

    unique_secrets = [secret(), secret()]
    with app.state.sessions() as db:
        for raw in unique_secrets:
            db.add(RegistrationInvite(digest=digest(raw), expires_at=instant + timedelta(days=1),
                                      max_uses=1, uses=0, revoked=False))
        db.commit()
    responses = race([lambda c, i=i: c.post("/v1/auth/password/register", json={
        "username": "  UNIQUE_RACE  " if i == 0 else "unique_race", "password": password,
        "invite_code": unique_secrets[i], "device_id": str(uuid4())}) for i in range(2)])
    assert sorted(r.status_code for r in responses) == [201, 409], "canonical username uniqueness race failed"
    with app.state.sessions() as db:
        assert len(list(db.scalars(select(PasswordCredential).where(PasswordCredential.username == "unique_race")))) == 1
        consumed = list(db.scalars(select(RegistrationInvite.uses).where(RegistrationInvite.digest.in_([digest(raw) for raw in unique_secrets]))))
        assert sorted(consumed) == [0, 1], "failed registration consumed its invite"

    # A password change must serialize against a concurrent login. Depending on
    # lock order, old-password login either precedes the change or is rejected.
    change_headers = {"Authorization": "Bearer " + registered["access_token"]}
    responses = race([
        lambda c: c.post("/v1/auth/password/change", headers=change_headers,
                         json={"current_password": password, "new_password": "Changed synthetic password"}),
        lambda c: c.post("/v1/auth/password/login", json={"username": username, "password": password,
                          "device_id": str(uuid4())}),
    ])
    assert responses[0].status_code == 200, "password change failed"
    assert responses[1].status_code in {200, 401}, "login/password change race failed"
    with TestClient(app) as client:
        if responses[1].status_code == 200:
            assert client.get("/v1/me", headers={"Authorization": "Bearer " + responses[1].json()["access_token"]}).status_code == 401
        assert client.get("/v1/me", headers=change_headers).status_code == 401
        changed = responses[0].json()
        assert changed["auth_provider"] == "password"
        assert client.get("/v1/me", headers={"Authorization": "Bearer " + changed["access_token"]}).status_code == 200
        assert client.post("/v1/auth/password/login", json={"username": username, "password": "Changed synthetic password",
                           "device_id": str(uuid4())}).status_code == 200

    # Exercise the actual admin reset path with private synthetic getpass input.
    from app import accounts
    import contextlib
    import io
    previous_getpass = accounts.getpass
    reset_password = "Reset synthetic password"
    accounts.getpass = lambda _prompt: reset_password
    def reset(_client):
        with contextlib.redirect_stdout(io.StringIO()):
            accounts.main(["reset-password", username])
        return "reset"
    try:
        responses = race([
            reset,
            lambda c: c.post("/v1/auth/password/login", json={"username": username,
                "password": "Changed synthetic password", "device_id": str(uuid4())}),
        ])
    finally:
        accounts.getpass = previous_getpass
    assert responses[0] == "reset"
    assert responses[1].status_code in {200, 401}, "login/admin reset race failed"
    with TestClient(app) as client:
        if responses[1].status_code == 200:
            assert client.get("/v1/me", headers={"Authorization": "Bearer " + responses[1].json()["access_token"]}).status_code == 401
        assert client.post("/v1/auth/password/login", json={"username": username, "password": reset_password,
                           "device_id": str(uuid4())}).status_code == 200
    engine.dispose()
    print(json.dumps({"status": "passed", "database": "disposable-verification-only", "checks": [
        "populated legacy PostgreSQL migration and metadata parity", "concurrent overlapping confirmation isolation",
        "atomic durable reservation and projection tasks", "concurrent snapshot CAS", "concurrent grant/privacy reduction",
        "mixed event-visibility snapshot/JSON/ICS projection", "event-bound reduction and legacy-event migration",
        "receiver unsubscribe/consumed and fresh redemption serialization", "receiver/owner grant/link revocation serialization",
        "single-use registration invite concurrency", "canonical username registration race",
        "password change/login session revocation isolation", "admin reset/login session revocation isolation"]}))


if __name__ == "__main__":
    run()
