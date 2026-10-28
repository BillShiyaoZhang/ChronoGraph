from datetime import timedelta
from uuid import uuid4
from sqlalchemy import select
from app.models import BusyEvent, Source
from conftest import login, source, grant, window


def event(a, b, **details):
    return {"id": str(uuid4()), "start": a.isoformat(), "end": b.isoformat(), "is_all_day": False,
            "timezone": "UTC", "availability": "busy", **details}


def test_snapshot_generation_retries_scope_and_ownership(api):
    client, app, _ = api
    owner, stranger = login(api, "a"), login(api, "b")
    a, b = window()
    src, snapshot = source(api, owner, events=[event(a, a + timedelta(hours=1))])
    path = f"/v1/sources/{src['id']}/snapshot"
    assert client.put(path, headers=owner["headers"], json=snapshot).json()["generation"] == 1
    changed = {**snapshot, "events": []}
    assert client.put(path, headers=owner["headers"], json=changed).status_code == 409
    assert client.put(path, headers=stranger["headers"], json=snapshot).status_code == 404
    changed.update(snapshot_id=str(uuid4()), expected_generation=0)
    assert client.put(path, headers=owner["headers"], json=changed).status_code == 409
    changed.update(expected_generation=1, events=[event(a, a + timedelta(hours=1), notes="PRIVATE")])
    r = client.put(path, headers=owner["headers"], json=changed)
    assert r.status_code == 422 and "PRIVATE" not in r.text
    with app.state.sessions() as db:
        assert db.get(Source, src["id"]).generation == 1
        assert len(list(db.scalars(select(BusyEvent)))) == 1


def test_snapshot_input_bounds_and_device_ownership(api):
    client, _, _ = api
    owner = login(api, "a")
    src, snapshot = source(api, owner)
    other_device = login(api, "a")
    r = client.put(f"/v1/sources/{src['id']}/snapshot", headers=other_device["headers"],
                   json={**snapshot, "snapshot_id": str(uuid4()), "expected_generation": 1})
    assert r.status_code == 403
    bad = {**snapshot, "snapshot_id": str(uuid4()), "window_end": "2040-01-01T00:00:00Z"}
    assert client.put(f"/v1/sources/{src['id']}/snapshot", headers=owner["headers"], json=bad).status_code == 422
    a, _ = window()
    item = event(a, a + timedelta(hours=1))
    bad = {**snapshot, "snapshot_id": str(uuid4()), "events": [item, item]}
    assert client.put(f"/v1/sources/{src['id']}/snapshot", headers=owner["headers"], json=bad).status_code == 422


def test_single_recipient_grants_revocation_and_link_owner(api):
    client, _, _ = api
    owner, viewer, stranger = login(api, "a"), login(api, "b"), login(api, "c")
    src, _ = source(api, owner)
    link = grant(api, owner, src, viewer)
    assert link["join_url"].startswith("https://example.com/chronograph/join/")
    assert client.post("/v1/share-links/redeem", headers=stranger["headers"], json={"token": link["token"]}).status_code == 409
    assert len(client.get("/v1/shared-sources", headers=viewer["headers"]).json()) == 1
    assert client.delete(f"/v1/share-links/{link['id']}", headers=viewer["headers"]).status_code == 404
    path = f"/v1/sources/{src['id']}/grants/{viewer['user']['id']}"
    assert client.delete(path, headers=owner["headers"]).status_code == 204
    assert client.get("/v1/shared-sources", headers=viewer["headers"]).json() == []
    assert client.post("/v1/share-links/redeem", headers=viewer["headers"], json={"token": link["token"]}).status_code == 409
    assert client.delete(f"/v1/share-links/{link['id']}", headers=owner["headers"]).status_code == 204


def test_ics_projection_revocation_and_privacy_reduction(api):
    client, app, _ = api
    owner, viewer = login(api, "a"), login(api, "b")
    a, _ = window()
    details = {"title": "SECRET TITLE", "location": "SECRET LOCATION", "notes": "SECRET NOTE\nBEGIN:VEVENT"}
    src, _ = source(api, owner, "full", [event(a, a + timedelta(hours=1), **details)])
    opaque = client.post(f"/v1/sources/{src['id']}/feed-links", headers=owner["headers"], json={}).json()
    full = client.post(f"/v1/sources/{src['id']}/feed-links", headers=owner["headers"], json={"privacy": "full"}).json()
    path = "/v1/feeds/" + opaque["url"].split("/")[-1]
    output = client.get(path)
    assert output.status_code == 200 and "SECRET" not in output.text
    full_path = "/v1/feeds/" + full["url"].split("/")[-1]
    assert "SECRET NOTE\\nBEGIN:VEVENT" in client.get(full_path).text
    grant(api, owner, src, viewer, "full")
    reduced = client.patch(f"/v1/sources/{src['id']}", headers=owner["headers"], json={"upload_level": "opaque"})
    assert reduced.status_code == 200
    assert "SECRET" not in client.get(full_path).text
    with app.state.sessions() as db:
        stored = db.scalars(select(BusyEvent)).first()
        assert stored.title is None and stored.notes is None and stored.location is None
    assert client.delete(f"/v1/feed-links/{opaque['id']}", headers=owner["headers"]).status_code == 204
    assert client.get(path).status_code == 404


def test_narrow_snapshot_removes_old_rows_and_rejects_outside_coverage(api):
    client, app, _ = api
    owner, viewer = login(api, "a"), login(api, "b")
    a, b = window()
    src, snapshot = source(api, owner, "full", [event(a, a + timedelta(hours=1), title="OLD SECRET")])
    grant(api, owner, src, viewer, "full")
    snapshot.update(snapshot_id=str(uuid4()), expected_generation=1, window_start=(a + timedelta(days=1)).isoformat(), events=[])
    assert client.put(f"/v1/sources/{src['id']}/snapshot", headers=owner["headers"], json=snapshot).status_code == 200
    r = client.get(f"/v1/sources/{src['id']}/events", headers=viewer["headers"], params={"start": a.isoformat(), "end": b.isoformat()})
    assert r.status_code == 409 and "OLD SECRET" not in r.text
    with app.state.sessions() as db:
        assert list(db.scalars(select(BusyEvent))) == []


def test_shared_events_apply_grant_projection_and_delete_cascades(api):
    client, _, _ = api
    owner, viewer = login(api, "a"), login(api, "b")
    a, b = window()
    src, _ = source(api, owner, "full", [event(a, a + timedelta(hours=1), title="PRIVATE", notes="NOTES")])
    link = grant(api, owner, src, viewer, "opaque")
    path = f"/v1/sources/{src['id']}/events"
    output = client.get(path, headers=viewer["headers"], params={"start": a.isoformat(), "end": b.isoformat()})
    assert output.status_code == 200 and "PRIVATE" not in output.text and "notes" not in output.text
    assert client.delete(f"/v1/sources/{src['id']}", headers=owner["headers"]).status_code == 204
    assert client.get("/v1/shared-sources", headers=viewer["headers"]).json() == []
    assert client.post("/v1/share-links/redeem", headers=viewer["headers"], json={"token": link["token"]}).status_code == 404


def test_all_day_ics_preserves_dates_in_event_zone_across_dst(api):
    from datetime import datetime, timezone
    from app.services import ics_document
    from app.models import BusyEvent, Source
    # New York's spring DST day has 23 elapsed hours, but remains one calendar day.
    item = BusyEvent(source_id=str(uuid4()), id=str(uuid4()), is_all_day=True, timezone="America/New_York",
        availability="busy", start=datetime(2027, 3, 14, 5, tzinfo=timezone.utc),
        end=datetime(2027, 3, 15, 4, tzinfo=timezone.utc))
    calendar = Source(id=item.source_id, generation=2, last_synced_at=datetime.now(timezone.utc))
    result = ics_document([item], calendar, "opaque")
    assert "DTSTART;VALUE=DATE:20270314\r\n" in result
    assert "DTEND;VALUE=DATE:20270315\r\n" in result
    assert "DTSTART:2027" not in result


def test_ics_utf8_folding_stays_within_75_octets(api):
    from datetime import datetime, timezone
    from app.services import ics_document
    from app.models import BusyEvent, Source
    day, _ = window()
    item = BusyEvent(source_id=str(uuid4()), id=str(uuid4()), is_all_day=False, timezone="UTC",
        availability="busy", start=day, end=day + timedelta(hours=1), title="很长的中文日程标题" * 40)
    calendar = Source(id=item.source_id, generation=2, last_synced_at=datetime.now(timezone.utc))
    result = ics_document([item], calendar, "partial")
    assert max(len(line.encode("utf-8")) for line in result.split("\r\n")) <= 75
    assert item.title in result.replace("\r\n ", "")
