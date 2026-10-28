from datetime import timedelta
from uuid import uuid4
from sqlalchemy import select
from app.models import Source, Reservation, DeviceTask
from conftest import pair, window, login, source, grant


def search_request(people):
    a, b = window()
    return {"participants": people, "window_start": a.isoformat(), "window_end": b.isoformat(),
            "duration_minutes": 60, "timezone": "UTC", "daily_start": "09:00", "daily_end": "21:00"}


def meeting_request(people, hour=12):
    a, _ = window()
    return {"request_id": str(uuid4()), "title": "Lunch", "start": (a + timedelta(hours=hour)).isoformat(),
            "end": (a + timedelta(hours=hour + 1)).isoformat(), "timezone": "UTC", "participants": people}


def test_matching_permissions_freshness_and_missing_coverage(api):
    client, app, _ = api
    a, b, sa, sb, people = pair(api)
    payload = search_request(people)
    r = client.post("/v1/availability/search", headers=a["headers"], json=payload)
    assert r.status_code == 200, r.text
    result = r.json()
    assert len(result["windows"]) == 3
    assert "T09:00:00" in result["windows"][0]["suggested_start"]
    assert "notes" not in r.text and "title" not in r.text
    empty_source, _ = source(api, b)
    with app.state.sessions() as db:
        db.get(Source, sb["id"]).coverage_start = None
        db.commit()
    r = client.post("/v1/availability/search", headers=a["headers"], json=payload)
    assert r.status_code == 409 and r.json()["detail"]["code"] == "missing_coverage"
    with app.state.sessions() as db:
        db.get(Source, sb["id"]).coverage_start = window()[0]
        db.get(Source, sb["id"]).last_synced_at = window()[0] - timedelta(days=10)
        db.commit()
    r = client.post("/v1/availability/search", headers=a["headers"], json=payload)
    assert r.status_code == 409 and r.json()["detail"]["code"] == "stale_source"
    client.delete(f"/v1/sources/{sb['id']}/grants/{a['user']['id']}", headers=b["headers"])
    assert client.post("/v1/availability/search", headers=a["headers"], json=payload).status_code == 403


def test_matching_busy_union_free_tentative_unknown_and_boundary(api):
    client, _, _ = api
    a, b, sa, sb, people = pair(api)
    day, upper = window()
    def ev(start, end, availability):
        return {"id": str(uuid4()), "start": (day + timedelta(hours=start)).isoformat(),
                "end": (day + timedelta(hours=end)).isoformat(), "availability": availability, "timezone": "UTC"}
    r = client.put(f"/v1/sources/{sb['id']}/snapshot", headers=b["headers"], json={"snapshot_id": str(uuid4()),
         "expected_generation": 1, "window_start": day.isoformat(), "window_end": upper.isoformat(),
         "events": [ev(9, 10, "busy"), ev(9.5, 11, "tentative"), ev(11, 12, "unknown"), ev(12, 14, "free")]})
    assert r.status_code == 200
    result = client.post("/v1/availability/search", headers=a["headers"], json=search_request(people)).json()
    assert "T12:00:00" in result["windows"][0]["suggested_start"]
    # Adjacent end/start is not a conflict and free-marked records do not block.
    assert "T21:00:00" in result["windows"][0]["end"]


def test_meeting_responses_revision_host_confirmation_cancel_and_tasks(api):
    client, app, _ = api
    a, b, sa, sb, people = pair(api)
    payload = meeting_request(people)
    r = client.post("/v1/meetings", headers=a["headers"], json=payload)
    assert r.status_code == 201, r.text
    meeting = r.json()
    path = "/v1/meetings/" + meeting["id"]
    assert client.post(path + "/confirm", headers=a["headers"], json={"revision": 1}).status_code == 409
    assert client.post(path + "/confirm", headers=b["headers"], json={"revision": 1}).status_code == 403
    assert client.post(path + "/response", headers=b["headers"], json={"revision": 2, "response": "accepted"}).status_code == 409
    assert client.post(path + "/response", headers=b["headers"], json={"revision": 1, "response": "tentative"}).status_code == 200
    assert client.post(path + "/confirm", headers=a["headers"], json={"revision": 1}).status_code == 409
    assert client.post(path + "/response", headers=b["headers"], json={"revision": 1, "response": "accepted"}).status_code == 200
    r = client.post(path + "/confirm", headers=a["headers"], json={"revision": 1})
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "confirmed"
    assert client.post(path + "/confirm", headers=a["headers"], json={"revision": 1}).status_code == 200
    tasks = client.get("/v1/device-tasks", headers=a["headers"], params={"device_id": a["device_id"]}).json()
    assert len(tasks) == 1 and tasks[0]["action"] == "upsert"
    assert client.post(f"/v1/device-tasks/{tasks[0]['id']}/ack", headers=b["headers"]).status_code == 404
    assert client.post(f"/v1/device-tasks/{tasks[0]['id']}/ack", headers=a["headers"]).status_code == 204
    assert client.post(f"/v1/device-tasks/{tasks[0]['id']}/ack", headers=a["headers"]).status_code == 204
    assert client.post(path + "/cancel", headers=b["headers"], json={"revision": 1}).status_code == 403
    assert client.post(path + "/cancel", headers=a["headers"], json={"revision": 1}).json()["status"] == "cancelled"
    assert client.post(path + "/cancel", headers=a["headers"], json={"revision": 1}).status_code == 200
    with app.state.sessions() as db:
        assert list(db.scalars(select(Reservation))) == []
        assert len(list(db.scalars(select(DeviceTask)))) == 4


def test_confirmed_reservations_block_second_meeting_and_matching(api):
    client, _, _ = api
    a, b, sa, sb, people = pair(api)
    payload = meeting_request(people)
    meetings = [client.post("/v1/meetings", headers=a["headers"], json={**payload, "request_id": str(uuid4())}).json() for _ in range(2)]
    for meeting in meetings:
        assert client.post(f"/v1/meetings/{meeting['id']}/response", headers=b["headers"],
                           json={"revision": 1, "response": "accepted"}).status_code == 200
    first, second = ("/v1/meetings/" + m["id"] for m in meetings)
    assert client.post(first + "/confirm", headers=a["headers"], json={"revision": 1}).status_code == 200
    r = client.post(second + "/confirm", headers=a["headers"], json={"revision": 1})
    assert r.status_code == 409 and r.json()["detail"]["code"] == "calendar_conflict"
    windows = client.post("/v1/availability/search", headers=a["headers"], json=search_request(people)).json()["windows"]
    assert "T12:00:00" in windows[0]["end"]
    assert "T13:00:00" in windows[1]["start"]


def test_amendment_resets_consent_and_releases_old_reservation(api):
    client, _, _ = api
    a, b, sa, sb, people = pair(api)
    payload = meeting_request(people)
    meeting = client.post("/v1/meetings", headers=a["headers"], json=payload).json()
    path = "/v1/meetings/" + meeting["id"]
    client.post(path + "/response", headers=b["headers"], json={"revision": 1, "response": "accepted"})
    client.post(path + "/confirm", headers=a["headers"], json={"revision": 1})
    updated = client.patch(path, headers=a["headers"], json={**meeting_request(people, 14), "revision": 1})
    assert updated.status_code == 200, updated.text
    result = updated.json()
    assert result["revision"] == 2 and result["status"] == "proposed"
    assert next(p for p in result["participants"] if p["user_id"] == b["user"]["id"])["response"] == "pending"
    assert client.post(path + "/confirm", headers=a["headers"], json={"revision": 1}).status_code == 409
    assert client.post(path + "/confirm", headers=a["headers"], json={"revision": 2}).status_code == 409


def test_nonparticipants_cannot_observe_or_mutate_meeting(api):
    client, _, _ = api
    a, b, sa, sb, people = pair(api)
    other = login(api, "outsider")
    meeting = client.post("/v1/meetings", headers=a["headers"], json=meeting_request(people)).json()
    path = "/v1/meetings/" + meeting["id"]
    assert client.get(path, headers=other["headers"]).status_code == 404
    assert client.post(path + "/response", headers=other["headers"], json={"revision": 1, "response": "accepted"}).status_code == 404
    assert client.get("/v1/meetings", headers=other["headers"]).json() == []


def test_account_deletion_cancels_shared_meeting_without_leaking_sources(api):
    client, _, _ = api
    a, b, sa, sb, people = pair(api)
    meeting = client.post("/v1/meetings", headers=a["headers"], json=meeting_request(people)).json()
    path = "/v1/meetings/" + meeting["id"]
    client.post(path + "/response", headers=b["headers"], json={"revision": 1, "response": "accepted"})
    client.post(path + "/confirm", headers=a["headers"], json={"revision": 1})
    r = client.delete("/v1/me", headers=b["headers"])
    assert r.status_code == 204, r.text
    assert client.get(path, headers=a["headers"]).json()["status"] == "cancelled"
    assert client.get("/v1/shared-sources", headers=a["headers"]).json() == []


def test_timezone_dst_grid_uses_local_wall_time(api):
    client, _, _ = api
    a, b, sa, sb, people = pair(api)
    payload = search_request(people)
    payload.update(timezone="Asia/Kathmandu", daily_start="09:00", daily_end="12:00")
    result = client.post("/v1/availability/search", headers=a["headers"], json=payload)
    assert result.status_code == 200
    # 09:00 Nepal is 03:15 UTC; grid is local, not rounded to whole UTC hours.
    assert "T03:15:00" in result.json()["windows"][0]["suggested_start"]


def test_meeting_creation_retry_is_idempotent_and_payload_bound(api):
    client, _, _ = api
    a, b, sa, sb, people = pair(api)
    payload = meeting_request(people)
    first = client.post("/v1/meetings", headers=a["headers"], json=payload)
    retry = client.post("/v1/meetings", headers=a["headers"], json=payload)
    assert first.status_code == retry.status_code == 201
    assert first.json()["id"] == retry.json()["id"]
    assert len(client.get("/v1/meetings", headers=a["headers"]).json()) == 1
    assert client.post("/v1/meetings", headers=a["headers"], json={**payload, "title": "Different"}).status_code == 409
    payload.pop("request_id")
    assert client.post("/v1/meetings", headers=a["headers"], json=payload).status_code == 422
