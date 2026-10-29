from datetime import timedelta
from uuid import uuid4

from sqlalchemy import select

from app.models import BusyEvent, DeviceTask, Grant, Participant, Reservation, ShareLink, Source
from conftest import grant, login, pair, source, window
from test_coordination import meeting_request, search_request
from test_sync_sharing import event


def test_unsubscribe_removes_only_callers_grant_and_access(api):
    client, app, _ = api
    owner, viewer, other = [login(api, name) for name in ("owner", "viewer", "other")]
    start, end = window()
    calendar, _ = source(api, owner, "full", [event(start, start + timedelta(hours=1), title="Original")])
    own, _ = source(api, viewer)
    link = grant(api, owner, calendar, viewer, "partial")
    grant(api, owner, calendar, other, "opaque")
    feed = client.post(f"/v1/sources/{calendar['id']}/feed-links", headers=owner["headers"], json={}).json()
    params = {"start": start.isoformat(), "end": end.isoformat()}
    events = f"/v1/sources/{calendar['id']}/events"
    people = [{"user_id": viewer["user"]["id"], "source_ids": [own["id"]]},
              {"user_id": owner["user"]["id"], "source_ids": [calendar["id"]]}]
    assert client.post("/v1/availability/search", headers=viewer["headers"], json=search_request(people)).status_code == 200
    path = f"/v1/shared-sources/{calendar['id']}"
    for _ in range(2):
        response = client.delete(path, headers=viewer["headers"])
        assert response.status_code == 204 and response.content == b""
    assert client.get("/v1/shared-sources", headers=viewer["headers"]).json() == []
    assert client.get(events, headers=viewer["headers"], params=params).status_code == 404
    denied = client.post("/v1/availability/search", headers=viewer["headers"], json=search_request(people))
    assert denied.status_code == 403 and denied.json()["detail"]["code"] == "source_access_denied"
    for account in (owner, other):
        assert client.get(events, headers=account["headers"], params=params).status_code == 200
    assert client.get("/v1/feeds/" + feed["url"].split("/")[-1]).status_code == 200
    with app.state.sessions() as db:
        stored = db.get(Source, calendar["id"])
        assert stored.generation == calendar["generation"]
        assert db.get(Grant, (calendar["id"], viewer["user"]["id"])) is None
        assert db.get(Grant, (calendar["id"], other["user"]["id"])) is not None
        assert len(list(db.scalars(select(BusyEvent).where(BusyEvent.source_id == calendar["id"])))) == 1
        consumed = db.get(ShareLink, link["id"])
        assert consumed.redeemed_by == viewer["user"]["id"] and not consumed.revoked
        assert not db.get(ShareLink, feed["id"]).revoked


def test_unsubscribe_auth_ownership_and_unknown_source_do_not_change_others(api):
    client, app, _ = api
    owner, viewer, stranger = [login(api, name) for name in ("owner", "viewer", "stranger")]
    calendar, _ = source(api, owner)
    grant(api, owner, calendar, viewer)
    path = f"/v1/shared-sources/{calendar['id']}"
    assert client.delete(path).status_code == 401
    response = client.delete(path, headers=owner["headers"])
    assert response.status_code == 403 and response.json()["detail"]["code"] == "owned_source"
    assert client.delete(path, headers=stranger["headers"]).status_code == 204
    assert client.delete(f"/v1/shared-sources/{uuid4()}", headers=viewer["headers"]).status_code == 204
    assert client.delete(f"/v1/sources/{calendar['id']}/grants/{viewer['user']['id']}", headers=stranger["headers"]).status_code == 404
    with app.state.sessions() as db:
        assert db.get(Source, calendar["id"]) is not None
        assert db.get(Grant, (calendar["id"], viewer["user"]["id"])) is not None


def test_unsubscribe_never_restores_consumed_link_and_fresh_link_requires_explicit_redeem(api):
    client, _, _ = api
    owner, viewer, stranger = [login(api, name) for name in ("owner", "viewer", "stranger")]
    calendar, _ = source(api, owner, "full")
    old = grant(api, owner, calendar, viewer, "full")
    assert client.delete(f"/v1/shared-sources/{calendar['id']}", headers=viewer["headers"]).status_code == 204
    for account in (viewer, stranger):
        denied = client.post("/v1/share-links/redeem", headers=account["headers"], json={"token": old["token"]})
        assert denied.status_code == 409 and denied.json()["detail"]["code"] == "link_already_used"
    fresh = client.post(f"/v1/sources/{calendar['id']}/share-links", headers=owner["headers"], json={"privacy": "opaque"}).json()
    # Merely loading received sources, the public landing or owner link lists cannot resubscribe.
    assert client.get("/join/" + fresh["token"]).status_code == 200
    assert client.get(f"/v1/sources/{calendar['id']}/share-links", headers=owner["headers"]).status_code == 200
    assert client.get("/v1/shared-sources", headers=viewer["headers"]).json() == []
    renewed = client.post("/v1/share-links/redeem", headers=viewer["headers"], json={"token": fresh["token"]})
    assert renewed.status_code == 200 and renewed.json()["privacy"] == "opaque"
    assert client.delete(f"/v1/sources/{calendar['id']}/grants/{viewer['user']['id']}", headers=owner["headers"]).status_code == 204
    assert client.post("/v1/share-links/redeem", headers=viewer["headers"], json={"token": fresh["token"]}).status_code == 409
    assert client.delete(f"/v1/shared-sources/{calendar['id']}", headers=viewer["headers"]).status_code == 204
    assert client.delete(f"/v1/sources/{calendar['id']}", headers=owner["headers"]).status_code == 204
    assert client.delete(f"/v1/shared-sources/{calendar['id']}", headers=viewer["headers"]).status_code == 204


def test_unsubscribe_preserves_confirmed_meeting_history_and_legacy_grants(api):
    client, app, _ = api
    host, guest, host_source, guest_source, people = pair(api)
    meeting = client.post("/v1/meetings", headers=host["headers"], json=meeting_request(people)).json()
    path = "/v1/meetings/" + meeting["id"]
    assert client.post(path + "/response", headers=guest["headers"], json={"revision": 1, "response": "accepted"}).status_code == 200
    assert client.post(path + "/confirm", headers=host["headers"], json={"revision": 1}).status_code == 200
    legacy, _ = source(api, host)
    with app.state.sessions() as db:
        before = {model: len(list(db.scalars(select(model)))) for model in (Participant, Reservation, DeviceTask)}
        # Legacy grants need no pairing-link provenance to be removable.
        db.add(Grant(source_id=legacy["id"], viewer_id=guest["user"]["id"], privacy="opaque"))
        db.commit()
    for calendar in (host_source, legacy):
        assert client.delete(f"/v1/shared-sources/{calendar['id']}", headers=guest["headers"]).status_code == 204
    for account in (host, guest):
        history = client.get(path, headers=account["headers"])
        assert history.status_code == 200 and history.json()["status"] == "confirmed"
        assert client.get("/v1/meetings", headers=account["headers"]).json()[0]["id"] == meeting["id"]
    with app.state.sessions() as db:
        for model, count in before.items():
            assert len(list(db.scalars(select(model)))) == count
        assert db.get(Source, host_source["id"]) is not None
        assert db.get(Grant, (guest_source["id"], host["user"]["id"])) is not None
