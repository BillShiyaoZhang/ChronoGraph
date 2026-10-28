from datetime import datetime, timedelta, time, timezone
from zoneinfo import ZoneInfo
from uuid import UUID
from sqlalchemy import select
from .models import Source, BusyEvent, Grant, User, Participant, Meeting, Reservation, Device, DeviceTask, now
from .security import fail, aware
from .timezones import event_timezone


PRIVACY_RANK = {"opaque": 0, "partial": 1, "full": 2}


def source_json(source):
    return {"id": source.id, "owner_id": source.owner_id, "device_id": source.device_id,
            "name": source.name, "upload_level": source.upload_level, "generation": source.generation,
            "coverage_start": aware(source.coverage_start) if source.coverage_start else None,
            "coverage_end": aware(source.coverage_end) if source.coverage_end else None,
            "last_synced_at": aware(source.last_synced_at) if source.last_synced_at else None}


def owner_source(db, source_id, user_id, lock=False):
    query = select(Source).where(Source.id == str(source_id), Source.owner_id == user_id)
    if lock:
        query = query.with_for_update()
    value = db.scalar(query.execution_options(populate_existing=True))
    if value is None:
        fail(404, "source_not_found", "Source is unavailable")
    return value


def check_level(privacy, source):
    if PRIVACY_RANK[privacy] > PRIVACY_RANK[source.upload_level]:
        fail(422, "privacy_exceeds_upload", "Sharing cannot include fields outside the source upload permission")


def shared_json(db, source, privacy):
    value = source_json(source)
    value.pop("device_id")
    value.pop("upload_level")
    privacy = min((privacy, source.upload_level), key=PRIVACY_RANK.get)
    value.update(owner_name=db.get(User, source.owner_id).display_name, privacy=privacy)
    return value


def accessible_sources(db, caller_id, selections, start, end, settings, require_self=True):
    selected = {str(p.user_id): p for p in selections}
    if require_self and caller_id not in selected:
        fail(422, "self_required", "Include yourself in the participants")
    results = []
    for owner_id, person in selected.items():
        account = db.get(User, owner_id)
        if account is None or account.deleted:
            fail(404, "participant_unavailable", "A participant is unavailable")
        for source_id in person.source_ids:
            source = db.get(Source, str(source_id))
            if source is None or source.owner_id != owner_id:
                fail(403, "source_access_denied", "A selected source is unavailable to you")
            if owner_id != caller_id and db.get(Grant, (source.id, caller_id)) is None:
                fail(403, "source_access_denied", "Calendar access is required for every selected source")
            if source.coverage_start is None or aware(source.coverage_start) > aware(start) or aware(source.coverage_end) < aware(end):
                fail(409, "missing_coverage", "A selected source does not cover the requested dates")
            if source.last_synced_at is None or aware(source.last_synced_at) < now() - timedelta(hours=settings.source_stale_hours):
                fail(409, "stale_source", "A selected source needs an update before comparing availability")
            results.append(source)
    return results


def busy_ranges(db, sources, people, start, end, exclude_meeting=None):
    intervals = []
    ids = [s.id for s in sources]
    for event in db.scalars(select(BusyEvent).where(BusyEvent.source_id.in_(ids), BusyEvent.start < end,
                                                    BusyEvent.end > start, BusyEvent.availability != "free")):
        intervals.append((max(aware(event.start), aware(start)), min(aware(event.end), aware(end))))
    q = select(Reservation).where(Reservation.user_id.in_(people), Reservation.start < end, Reservation.end > start)
    if exclude_meeting:
        q = q.where(Reservation.meeting_id != exclude_meeting)
    intervals.extend((max(aware(r.start), aware(start)), min(aware(r.end), aware(end))) for r in db.scalars(q))
    merged = []
    for a, b in sorted(intervals):
        if merged and a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(b, merged[-1][1]))
        else:
            merged.append((a, b))
    return merged


def search_windows(db, payload, sources):
    zone = ZoneInfo(payload.timezone)
    lower, upper = max(aware(payload.window_start), now()), aware(payload.window_end)
    people = [str(p.user_id) for p in payload.participants]
    busy = busy_ranges(db, sources, people, lower, upper)
    day = lower.astimezone(zone).date()
    last_day = upper.astimezone(zone).date()
    duration = timedelta(minutes=payload.duration_minutes)
    output = []
    while day <= last_day:
        day_start = max(lower, datetime.combine(day, time.fromisoformat(payload.daily_start), zone).astimezone(timezone.utc))
        day_end = min(upper, datetime.combine(day, time.fromisoformat(payload.daily_end), zone).astimezone(timezone.utc))
        cursor = day_start
        free = []
        for a, b in busy:
            if b <= cursor or a >= day_end:
                continue
            if a > cursor:
                free.append((cursor, min(a, day_end)))
            cursor = max(cursor, b)
        if cursor < day_end:
            free.append((cursor, day_end))
        for a, b in free:
            # Grid is in the requested wall-clock zone, including fractional UTC offsets.
            slot = a.replace(second=0, microsecond=0)
            if slot < a:
                slot += timedelta(minutes=1)
            local = slot.astimezone(zone)
            slot += timedelta(minutes=(-local.minute) % 15)
            if slot + duration <= b:
                output.append({"start": a, "end": b, "suggested_start": slot, "suggested_end": slot + duration})
        day += timedelta(days=1)
    return output


def meeting_json(db, value):
    return {"id": value.id, "host_id": value.host_id, "title": value.title,
            "start": aware(value.start), "end": aware(value.end), "timezone": value.timezone,
            "revision": value.revision, "status": value.status, "updated_at": aware(value.updated_at),
            "participants": [{"user_id": p.user_id, "response": p.response}
                             for p in db.scalars(select(Participant).where(Participant.meeting_id == value.id).order_by(Participant.user_id))]}


def visible_meeting(db, meeting_id, user_id, lock=False):
    q = select(Meeting).where(Meeting.id == str(meeting_id))
    if lock:
        q = q.with_for_update()
    meeting = db.scalar(q.execution_options(populate_existing=True))
    if meeting is None or db.get(Participant, (meeting.id, user_id)) is None:
        fail(404, "meeting_not_found", "Meeting is unavailable")
    return meeting


def check_revision(meeting, revision):
    if meeting.revision != revision:
        fail(409, "stale_revision", "This proposal changed; review the latest version")


def projection_tasks(db, meeting, action):
    """One designated oldest device per account; avoids duplicate physical calendar copies."""
    users = list(db.scalars(select(Participant.user_id).where(Participant.meeting_id == meeting.id)))
    for user_id in users:
        device = db.scalar(select(Device).where(Device.user_id == user_id).order_by(Device.created_at, Device.id))
        if device is None:
            continue
        existing = db.scalar(select(DeviceTask).where(DeviceTask.device_id == device.id, DeviceTask.meeting_id == meeting.id,
                                                     DeviceTask.revision == meeting.revision, DeviceTask.action == action))
        if existing:
            continue
        db.add(DeviceTask(user_id=user_id, device_id=device.id, meeting_id=meeting.id, revision=meeting.revision,
                          action=action, payload={"meeting_id": meeting.id, "revision": meeting.revision,
                          "title": meeting.title, "start": aware(meeting.start).isoformat(),
                          "end": aware(meeting.end).isoformat(), "timezone": meeting.timezone}))


def escape_ics(value):
    return str(value).replace("\\", "\\\\").replace("\r\n", "\n").replace("\r", "\n").replace("\n", "\\n").replace(";", "\\;").replace(",", "\\,")


def ics_document(events, source, privacy):
    def stamp(value):
        return aware(value).strftime("%Y%m%dT%H%M%SZ")
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//ChronoGraph//Calendar v1//EN", "CALSCALE:GREGORIAN"]
    for event in events:
        if event.is_all_day:
            zone = event_timezone(event.timezone)
            dates = ["DTSTART;VALUE=DATE:" + aware(event.start).astimezone(zone).strftime("%Y%m%d"),
                     "DTEND;VALUE=DATE:" + aware(event.end).astimezone(zone).strftime("%Y%m%d")]
        else:
            dates = [f"DTSTART:{stamp(event.start)}", f"DTEND:{stamp(event.end)}"]
        lines += ["BEGIN:VEVENT", f"UID:{event.id}.{source.id}@chronograph", f"DTSTAMP:{stamp(source.last_synced_at)}",
                  f"SEQUENCE:{source.generation}", *dates,
                  "SUMMARY:" + escape_ics(event.availability if privacy == "opaque" else (event.title or event.availability)),
                  "TRANSP:" + ("TRANSPARENT" if event.availability == "free" else "OPAQUE")]
        if privacy == "full":
            if event.location:
                lines.append("LOCATION:" + escape_ics(event.location))
            if event.notes:
                lines.append("DESCRIPTION:" + escape_ics(event.notes))
        lines.append("END:VEVENT")
    lines.append("END:VCALENDAR")
    # RFC 5545 folds by UTF-8 octets, never by Python character count.
    folded = []
    for line in lines:
        current = ""
        for char in line:
            if len((current + char).encode()) > 75:
                folded.append(current)
                current = " "
            current += char
        folded.append(current)
    return "\r\n".join(folded) + "\r\n"
