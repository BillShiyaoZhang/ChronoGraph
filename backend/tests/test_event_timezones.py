from datetime import datetime, time, timedelta, timezone
from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.schemas import MeetingCreate, Search
from app.timezones import event_timezone
from conftest import login, source, window


@pytest.mark.parametrize("name,minutes", [
    ("GMT+0800", 480), ("GMT+08:00", 480), ("UTC+0800", 480), ("UTC+08:00", 480),
    ("GMT+0530", 330), ("UTC+0545", 345), ("GMT-0330", -210), ("UTC-03:30", -210),
    ("GMT+1800", 1080), ("UTC-18:00", -1080), ("GMT+0000", 0),
])
def test_foundation_offset_names_keep_their_sign_and_minutes(name, minutes):
    assert event_timezone(name).utcoffset(None) == timedelta(minutes=minutes)


def test_iana_zones_keep_dst_and_etc_sign_conventions():
    new_york = event_timezone("America/New_York")
    assert datetime(2027, 3, 13, 12, tzinfo=new_york).utcoffset() == timedelta(hours=-5)
    assert datetime(2027, 3, 14, 12, tzinfo=new_york).utcoffset() == timedelta(hours=-4)
    # IANA's Etc/GMT names use the opposite sign to Foundation's GMT offsets.
    assert datetime(2026, 10, 29, tzinfo=event_timezone("Etc/GMT+8")).utcoffset() == timedelta(hours=-8)
    assert event_timezone("GMT+0800").utcoffset(None) == timedelta(hours=8)


@pytest.mark.parametrize("name", [
    "GMT+1860", "GMT+1801", "UTC-1801", "UTC+1900", "GMT+2400", "UTC+00:60",
    "GMT+8:00", "GMT+080", "GMT+08:0", "GMT+0800junk", " GMT+0800", "Mars/Fake", "",
])
def test_invalid_offsets_and_unknown_zones_have_no_fallback(name):
    with pytest.raises(ValueError, match="unknown event timezone"):
        event_timezone(name)


@pytest.mark.parametrize("name", ["GMT+0800", "GMT+0530", "GMT+0545", "GMT-0330"])
def test_snapshot_round_trip_and_all_day_feed_preserve_local_dates(api, name):
    client, _, _ = api
    owner = login(api)
    calendar, _ = source(api, owner)
    day, _ = window()
    zone = event_timezone(name)
    local_start = datetime.combine(day.date(), time.min, zone)
    local_end = local_start + timedelta(days=1)
    lower, upper = day - timedelta(days=1), day + timedelta(days=2)
    event_id = str(uuid4())
    response = client.put(f"/v1/sources/{calendar['id']}/snapshot", headers=owner["headers"], json={
        "snapshot_id": str(uuid4()), "expected_generation": 1,
        "window_start": lower.isoformat(), "window_end": upper.isoformat(),
        "events": [{"id": event_id, "start": local_start.isoformat(), "end": local_end.isoformat(),
                    "is_all_day": True, "timezone": name, "availability": "busy"}],
    })
    assert response.status_code == 200, response.text
    assert response.json()["generation"] == 2
    response = client.get(f"/v1/sources/{calendar['id']}/events", headers=owner["headers"], params={
        "start": lower.isoformat(), "end": upper.isoformat(),
    })
    assert response.status_code == 200, response.text
    values = response.json()
    assert len(values) == 1 and values[0]["id"] == event_id
    assert values[0]["timezone"] == name
    assert datetime.fromisoformat(values[0]["start"]) == local_start.astimezone(timezone.utc)
    link = client.post(f"/v1/sources/{calendar['id']}/feed-links", headers=owner["headers"], json={}).json()
    feed = client.get("/v1/feeds/" + link["url"].rsplit("/", 1)[1])
    assert feed.status_code == 200
    assert "DTSTART;VALUE=DATE:" + local_start.strftime("%Y%m%d") + "\r\n" in feed.text
    assert "DTEND;VALUE=DATE:" + local_end.strftime("%Y%m%d") + "\r\n" in feed.text


def test_bad_zone_snapshot_does_not_replace_last_successful_coverage(api):
    client, _, _ = api
    owner = login(api)
    day, upper = window()
    item = {"id": str(uuid4()), "start": day.isoformat(), "end": (day + timedelta(hours=1)).isoformat(),
            "timezone": "UTC", "availability": "busy"}
    calendar, old_snapshot = source(api, owner, events=[item])
    response = client.put(f"/v1/sources/{calendar['id']}/snapshot", headers=owner["headers"], json={
        **old_snapshot, "snapshot_id": str(uuid4()), "expected_generation": 1,
        "events": [{**item, "timezone": "GMT+1801"}],
    })
    assert response.status_code == 422
    assert response.json()["detail"]["issues"][0]["loc"] == ["body", "events", 0, "timezone"]
    current = client.get("/v1/sources", headers=owner["headers"]).json()[0]
    assert current["generation"] == calendar["generation"] == 1
    assert current["coverage_start"] == calendar["coverage_start"]
    assert current["coverage_end"] == calendar["coverage_end"]
    events = client.get(f"/v1/sources/{calendar['id']}/events", headers=owner["headers"], params={
        "start": day.isoformat(), "end": upper.isoformat(),
    }).json()
    assert len(events) == 1 and events[0]["id"] == item["id"] and events[0]["timezone"] == "UTC"


def test_matching_and_meeting_zones_remain_iana_only():
    day, upper = window()
    people = [{"user_id": str(uuid4()), "source_ids": [str(uuid4())]} for _ in range(2)]
    with pytest.raises(ValidationError, match="IANA timezone"):
        Search.model_validate({"participants": people, "window_start": day, "window_end": upper,
                               "timezone": "GMT+0800"})
    with pytest.raises(ValidationError, match="IANA timezone"):
        MeetingCreate.model_validate({"participants": people, "start": day,
                                      "end": day + timedelta(hours=1), "timezone": "GMT+0800"})
