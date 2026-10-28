from datetime import datetime, time, timezone as utc_timezone
from enum import Enum
from typing import Annotated, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
import re
from pydantic import BaseModel, ConfigDict, Field, AwareDatetime, SecretStr, field_validator, model_validator
from .timezones import event_timezone


class DTO(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Privacy(str, Enum):
    opaque = "opaque"
    partial = "partial"
    full = "full"


class AppleLogin(DTO):
    challenge_id: UUID
    identity_token: str = Field(min_length=20, max_length=16_000)
    device_id: UUID
    device_name: str = Field(default="iPhone", min_length=1, max_length=100)


def canonical_username(value: str):
    value = value.strip().lower()
    if re.fullmatch(r"[a-z0-9._-]{3,32}", value) is None:
        raise ValueError("Username must contain 3–32 ASCII letters, digits, dots, underscores or hyphens")
    return value


def validate_password(value: SecretStr):
    raw = value.get_secret_value()
    try:
        size = len(raw.encode("utf-8"))
    except UnicodeEncodeError:
        raise ValueError("Password must use valid Unicode characters") from None
    if not 12 <= len(raw) <= 128 or size > 512:
        raise ValueError("Password must contain 12–128 characters and at most 512 UTF-8 bytes")
    return value


class PasswordLogin(DTO):
    username: str = Field(max_length=128)
    password: SecretStr
    device_id: UUID
    device_name: str = Field(default="iPhone", min_length=1, max_length=100)
    _username = field_validator("username")(canonical_username)
    _password = field_validator("password")(validate_password)


class PasswordRegister(PasswordLogin):
    invite_code: SecretStr = Field(min_length=20, max_length=200)
    display_name: str | None = Field(default=None, min_length=1, max_length=100)


class PasswordChange(DTO):
    current_password: SecretStr
    new_password: SecretStr
    _password = field_validator("current_password", "new_password")(validate_password)


class UserPatch(DTO):
    display_name: str = Field(min_length=1, max_length=100)


class SourceCreate(DTO):
    id: UUID
    name: str = Field(min_length=1, max_length=120)
    upload_level: Privacy = Privacy.opaque
    device_id: UUID


class SourcePatch(DTO):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    upload_level: Privacy | None = None


class Interval(DTO):
    start: AwareDatetime
    end: AwareDatetime

    @field_validator("start", "end")
    @classmethod
    def utc(cls, value):
        return value.astimezone(utc_timezone.utc)

    @model_validator(mode="after")
    def valid_interval(self):
        if self.end <= self.start:
            raise ValueError("end must be later than start")
        return self


class EventInput(Interval):
    id: UUID
    series_id: UUID | None = None
    is_all_day: bool = False
    timezone: str = Field(default="UTC", min_length=1, max_length=100)
    availability: Literal["busy", "free", "tentative", "unavailable", "unknown"] = "busy"
    title: str | None = Field(default=None, max_length=500)
    location: str | None = Field(default=None, max_length=1000)
    notes: str | None = Field(default=None, max_length=10_000)

    @field_validator("timezone")
    @classmethod
    def zone(cls, value):
        event_timezone(value)
        return value


class Snapshot(DTO):
    snapshot_id: UUID
    expected_generation: int = Field(ge=0)
    window_start: AwareDatetime
    window_end: AwareDatetime
    events: list[EventInput] = Field(max_length=20_000)

    @field_validator("window_start", "window_end")
    @classmethod
    def utc(cls, value):
        return value.astimezone(utc_timezone.utc)

    @model_validator(mode="after")
    def valid(self):
        if not 0 < (self.window_end - self.window_start).total_seconds() <= 180 * 86400:
            raise ValueError("snapshot window must be positive and at most 180 days")
        ids = [e.id for e in self.events]
        if len(set(ids)) != len(ids):
            raise ValueError("duplicate event IDs")
        if any(e.start >= self.window_end or e.end <= self.window_start for e in self.events):
            raise ValueError("all events must overlap the snapshot window")
        return self


class LinkInput(DTO):
    privacy: Privacy = Privacy.opaque
    expires_in_days: int = Field(default=30, ge=1, le=365)


class Redeem(DTO):
    token: str = Field(min_length=20, max_length=200)


class PersonSelection(DTO):
    user_id: UUID
    source_ids: list[UUID] = Field(min_length=1, max_length=30)

    @field_validator("source_ids")
    @classmethod
    def unique_sources(cls, value):
        if len(set(value)) != len(value):
            raise ValueError("source IDs must be unique")
        return value


class Search(DTO):
    participants: list[PersonSelection] = Field(min_length=2, max_length=20)
    window_start: AwareDatetime
    window_end: AwareDatetime
    duration_minutes: int = Field(default=60, ge=15, le=1440)
    timezone: str = "UTC"
    daily_start: str = "09:00"
    daily_end: str = "21:00"

    @model_validator(mode="after")
    def valid(self):
        if not 0 < (self.window_end - self.window_start).total_seconds() <= 31 * 86400:
            raise ValueError("search window must be positive and at most 31 days")
        if len(set(p.user_id for p in self.participants)) != len(self.participants):
            raise ValueError("participants must be unique")
        try:
            ZoneInfo(self.timezone)
            a, b = time.fromisoformat(self.daily_start), time.fromisoformat(self.daily_end)
            if a >= b or a.second or b.second or a.tzinfo or b.tzinfo:
                raise ValueError()
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError("use an IANA timezone and increasing HH:MM daily times")
        return self


class MeetingCreate(Interval):
    request_id: UUID | None = None
    title: str = Field(default="ChronoGraph meeting", min_length=1, max_length=200)
    timezone: str = "UTC"
    participants: list[PersonSelection] = Field(min_length=2, max_length=20)

    @model_validator(mode="after")
    def valid(self):
        try:
            ZoneInfo(self.timezone)
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError("unknown IANA timezone")
        if len(set(p.user_id for p in self.participants)) != len(self.participants):
            raise ValueError("participants must be unique")
        if (self.end - self.start).total_seconds() > 86400:
            raise ValueError("meetings may be at most 24 hours")
        return self


class Version(DTO):
    revision: int = Field(ge=1)


class MeetingPatch(MeetingCreate):
    revision: int = Field(ge=1)


class MeetingResponse(Version):
    response: Literal["accepted", "tentative", "declined"]
