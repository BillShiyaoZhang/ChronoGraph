"""Timezone interpretation for uploaded calendar events.

Foundation emits fixed-offset names such as GMT+0800 in addition to IANA names.
Keep the supplied name in storage and resolve the same meaning for validation and
all-day export. Availability/meeting zones intentionally remain IANA-only.
"""
from datetime import timedelta, timezone, tzinfo
import re
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


_FOUNDATION_OFFSET = re.compile(r"(?:GMT|UTC)([+-])([0-9]{2}):?([0-9]{2})")


def event_timezone(value: str) -> tzinfo:
    if not value or len(value) > 100:
        raise ValueError("unknown event timezone")
    try:
        return ZoneInfo(value)
    except (ZoneInfoNotFoundError, ValueError):
        pass
    match = _FOUNDATION_OFFSET.fullmatch(value)
    if match is None:
        raise ValueError("unknown event timezone")
    sign, hours, minutes = match.groups()
    hours, minutes = int(hours), int(minutes)
    # NSTimeZone supports fixed offsets through exactly +/-18:00. Do not accept
    # malformed or out-of-range names, or silently substitute the server's zone.
    if hours > 18 or minutes > 59 or (hours == 18 and minutes != 0):
        raise ValueError("unknown event timezone")
    offset = timedelta(minutes=(hours * 60 + minutes) * (1 if sign == "+" else -1))
    return timezone(offset, name=value)
