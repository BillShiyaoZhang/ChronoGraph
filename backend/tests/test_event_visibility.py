"""Mixed projections share one bounded source without transmitting local calendar identities."""
from datetime import timedelta
import hashlib
import json
from uuid import uuid4

import pytest
from sqlalchemy import select
from app.models import BusyEvent, Source
from conftest import grant, login, pair, source, window


def item(start, end, **fields):
    return {"id": str(uuid4()), "start": start.isoformat(), "end": end.isoformat(), **fields}


def read_events(client, user, calendar):
    start, end = window()
    response = client.get(f"/v1/sources/{calendar['id']}/events", headers=user["headers"],
                          params={"start": start.isoformat(), "end": end.isoformat()})
    assert response.status_code == 200, response.text
    return {event["id"]: event for event in response.json()}


def feed_text(client, owner, calendar, privacy="full"):
    response = client.post(f"/v1/sources/{calendar['id']}/feed-links", headers=owner["headers"], json={"privacy": privacy})
    assert response.status_code == 201, response.text
    path = "/v1/feeds/" + response.json()["url"].split("/")[-1]
    result = client.get(path)
    assert result.status_code == 200, result.text
    return result.text


def event_block(document, identity):
    return next(block for block in document.split("BEGIN:VEVENT\r\n")[1:] if f"UID:{identity}." in block)


def test_merged_source_keeps_each_event_and_occurrence_bound_in_json_and_ics(api):
    client, app, _ = api
    owner, full_viewer, partial_viewer = [login(api, name) for name in ("owner", "full-viewer", "partial-viewer")]
    day, _ = window()
    series = str(uuid4())
    events = [
        item(day + timedelta(hours=9), day + timedelta(hours=10), visibility="opaque", series_id=series),
        item(day + timedelta(hours=10), day + timedelta(hours=11), visibility="partial", title="TITLE ONLY"),
        item(day + timedelta(hours=11), day + timedelta(hours=12), visibility="full", series_id=series,
             title="DETAILED TITLE", location="DETAILED LOCATION", notes="DETAILED NOTES"),
    ]
    calendar, _ = source(api, owner, "full", events)
    grant(api, owner, calendar, full_viewer, "full")
    grant(api, owner, calendar, partial_viewer, "partial")
    for reader in (owner, full_viewer):
        output = read_events(client, reader, calendar)
        assert output[events[0]["id"]]["visibility"] == "opaque"
        assert "title" not in output[events[0]["id"]]
        assert "notes" not in output[events[0]["id"]]
        assert output[events[1]["id"]]["title"] == "TITLE ONLY"
        assert output[events[1]["id"]]["visibility"] == "partial"
        assert "location" not in output[events[1]["id"]]
        assert output[events[2]["id"]]["notes"] == "DETAILED NOTES"
        assert output[events[2]["id"]]["visibility"] == "full"
    restricted = read_events(client, partial_viewer, calendar)
    assert restricted[events[0]["id"]]["visibility"] == "opaque"
    assert restricted[events[2]["id"]]["visibility"] == "partial"
    assert restricted[events[2]["id"]]["title"] == "DETAILED TITLE"
    assert all("notes" not in event and "location" not in event for event in restricted.values())
    document = feed_text(client, owner, calendar)
    opaque = event_block(document, events[0]["id"])
    partial = event_block(document, events[1]["id"])
    detailed = event_block(document, events[2]["id"])
    assert "SUMMARY:busy\r\n" in opaque and "LOCATION:" not in opaque and "DESCRIPTION:" not in opaque
    assert "SUMMARY:TITLE ONLY\r\n" in partial and "LOCATION:" not in partial and "DESCRIPTION:" not in partial
    assert "LOCATION:DETAILED LOCATION\r\n" in detailed and "DESCRIPTION:DETAILED NOTES\r\n" in detailed
    restricted_feed = feed_text(client, owner, calendar, "partial")
    assert "DETAILED TITLE" in restricted_feed and "DETAILED LOCATION" not in restricted_feed and "DETAILED NOTES" not in restricted_feed
    with app.state.sessions() as db:
        assert {event.visibility for event in db.scalars(select(BusyEvent))} == {"opaque", "partial", "full"}
        assert len(list(db.scalars(select(BusyEvent).where(BusyEvent.series_id == series)))) == 2


@pytest.mark.parametrize("source_level,fields", [
    ("full", {"visibility": "opaque", "title": "REJECTED PRIVATE TITLE"}),
    ("full", {"visibility": "partial", "notes": "REJECTED PRIVATE NOTES"}),
    ("full", {"visibility": "opaque", "location": "REJECTED PRIVATE LOCATION"}),
    ("partial", {"visibility": "full"}),
    ("opaque", {"visibility": "partial"}),
    ("full", {"visibility": "excluded"}),
])
def test_invalid_event_scope_rejects_the_whole_snapshot_without_input_echo(api, source_level, fields):
    client, app, _ = api
    owner = login(api, "owner")
    calendar, snapshot = source(api, owner, source_level)
    day, _ = window()
    rejected = {**snapshot, "snapshot_id": str(uuid4()), "expected_generation": 1,
                "events": [item(day, day + timedelta(hours=1), **fields)]}
    response = client.put(f"/v1/sources/{calendar['id']}/snapshot", headers=owner["headers"], json=rejected)
    assert response.status_code == 422
    assert "REJECTED PRIVATE" not in response.text
    with app.state.sessions() as db:
        assert db.get(Source, calendar["id"]).generation == 1
        assert list(db.scalars(select(BusyEvent))) == []


def test_source_reduction_cannot_reexpand_event_bound_or_existing_grant(api):
    client, app, _ = api
    owner, viewer = login(api, "owner"), login(api, "viewer")
    day, _ = window()
    events = [item(day, day + timedelta(hours=1), visibility="opaque"),
              item(day + timedelta(hours=1), day + timedelta(hours=2), visibility="full",
                   title="RETAINED TITLE", location="REMOVED LOCATION", notes="REMOVED NOTES")]
    calendar, snapshot = source(api, owner, "full", events)
    grant(api, owner, calendar, viewer, "full")
    path = f"/v1/sources/{calendar['id']}"
    reduced = client.patch(path, headers=owner["headers"], json={"upload_level": "partial"})
    assert reduced.status_code == 200
    with app.state.sessions() as db:
        assert db.get(BusyEvent, (calendar["id"], events[1]["id"])).visibility == "partial"
        assert db.get(BusyEvent, (calendar["id"], events[1]["id"])).notes is None
    assert client.patch(path, headers=owner["headers"], json={"upload_level": "full"}).status_code == 200
    output = read_events(client, owner, calendar)
    assert output[events[0]["id"]]["visibility"] == "opaque"
    assert output[events[1]["id"]]["visibility"] == "partial"
    assert "notes" not in output[events[1]["id"]]
    assert client.get("/v1/shared-sources", headers=viewer["headers"]).json()[0]["privacy"] == "partial"
    document = feed_text(client, owner, calendar, "full")
    assert "RETAINED TITLE" in document and "REMOVED" not in document
    # An obsolete client cannot overwrite the reduction with a previously accepted body.
    assert client.put(path + "/snapshot", headers=owner["headers"], json=snapshot).status_code == 409


def test_old_client_snapshot_infers_visibility_and_preupgrade_retry_is_accepted(api):
    client, app, _ = api
    owner = login(api, "legacy")
    day, end = window()
    event = item(day, day + timedelta(hours=1), title="LEGACY TITLE", notes="LEGACY NOTES")
    calendar, snapshot = source(api, owner, "full", [event])
    # Recorded pre-visibility Pydantic wire encoding: inherited interval fields precede event fields.
    stamp = lambda value: value.isoformat().replace("+00:00", "Z")
    legacy_body = {"snapshot_id": snapshot["snapshot_id"], "expected_generation": 0,
                   "window_start": stamp(day), "window_end": stamp(end), "events": [{
                       "start": stamp(day), "end": stamp(day + timedelta(hours=1)), "id": event["id"],
                       "series_id": None, "is_all_day": False, "timezone": "UTC", "availability": "busy",
                       "title": "LEGACY TITLE", "location": None, "notes": "LEGACY NOTES"}]}
    legacy_digest = hashlib.sha256(json.dumps(legacy_body, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    with app.state.sessions() as db:
        db.get(Source, calendar["id"]).snapshot_digest = legacy_digest
        db.get(BusyEvent, (calendar["id"], event["id"])).visibility = None
        db.commit()
    retry = client.put(f"/v1/sources/{calendar['id']}/snapshot", headers=owner["headers"], json=snapshot)
    assert retry.status_code == 200 and retry.json()["generation"] == 1
    result = read_events(client, owner, calendar)[event["id"]]
    assert result["visibility"] == "full" and result["notes"] == "LEGACY NOTES"


def test_mixed_events_block_availability_without_disclosing_details_and_omitted_events_do_not(api):
    client, _, _ = api
    owner, viewer, own, theirs, people = pair(api, "full")
    day, end = window()
    events = [item(day + timedelta(hours=9), day + timedelta(hours=10), visibility="opaque"),
              item(day + timedelta(hours=10), day + timedelta(hours=11), visibility="partial", title="PRIVATE TITLE"),
              item(day + timedelta(hours=11), day + timedelta(hours=12), visibility="full", availability="free", notes="PRIVATE NOTES")]
    response = client.put(f"/v1/sources/{theirs['id']}/snapshot", headers=viewer["headers"], json={
        "snapshot_id": str(uuid4()), "expected_generation": 1, "window_start": day.isoformat(), "window_end": end.isoformat(), "events": events})
    assert response.status_code == 200
    search = {"participants": people, "window_start": day.isoformat(), "window_end": end.isoformat(),
              "duration_minutes": 60, "timezone": "UTC", "daily_start": "09:00", "daily_end": "21:00"}
    result = client.post("/v1/availability/search", headers=owner["headers"], json=search)
    assert result.status_code == 200, result.text
    assert "T11:00:00" in result.json()["windows"][0]["suggested_start"]
    assert "T21:00:00" in result.json()["windows"][0]["end"]
    assert "PRIVATE" not in result.text and "title" not in result.text and "notes" not in result.text


def test_per_event_snapshot_updates_preserve_meeting_revision_and_conflict_checks(api):
    client, _, _ = api
    owner, viewer, own, theirs, people = pair(api, "full")
    day, end = window()
    meeting = client.post("/v1/meetings", headers=owner["headers"], json={
        "request_id": str(uuid4()), "title": "Synthetic agreement", "start": (day + timedelta(hours=12)).isoformat(),
        "end": (day + timedelta(hours=13)).isoformat(), "timezone": "UTC", "participants": people}).json()
    path = "/v1/meetings/" + meeting["id"]
    assert client.post(path + "/response", headers=viewer["headers"], json={"revision": 1, "response": "accepted"}).status_code == 200
    changed = {"snapshot_id": str(uuid4()), "expected_generation": 1, "window_start": day.isoformat(), "window_end": end.isoformat(),
               "events": [item(day + timedelta(hours=12), day + timedelta(hours=13), visibility="opaque")]}
    assert client.put(f"/v1/sources/{theirs['id']}/snapshot", headers=viewer["headers"], json=changed).status_code == 200
    response = client.post(path + "/confirm", headers=owner["headers"], json={"revision": 1})
    assert response.status_code == 409 and response.json()["detail"]["code"] == "calendar_conflict"
    current = client.get(path, headers=owner["headers"]).json()
    assert current["revision"] == 1 and current["status"] == "proposed"
