import Foundation
import Testing
@testable import ChronoGraph

struct CloudPrivacyTests {
    private func source() -> SourceEventSnapshot {
        SourceEventSnapshot(calendarID: "private-calendar-id", calendarItemIdentifier: "private-event-id",
            externalIdentifier: "private-provider-id", title: "Private appointment", startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_003_600), location: "Private address", notes: "Private notes",
            timeZoneIdentifier: "Asia/Shanghai", readTimeZoneIdentifier: "Asia/Shanghai", availability: .busy)
    }
    @Test func opaqueUploadDoesNotSerializeSourceDetailsOrIdentifiers() throws {
        let projected = try CloudSnapshotProjection.project(source(), sourceID: UUID(), level: .opaque, key: Data(repeating: 3, count: 32))
        let data = try CloudJSON.encoder().encode(projected)
        let text = String(decoding: data, as: UTF8.self)
        #expect(projected.title == nil && projected.location == nil && projected.notes == nil)
        #expect(!text.contains("private-event-id"))
        #expect(!text.contains("private-calendar-id"))
        #expect(!text.contains("private-provider-id"))
        #expect(!text.contains("Private"))
        #expect(projected.start == source().startDate)
    }
    @Test func detailLevelsCannotAccidentallyUploadNotes() throws {
        let key = Data(repeating: 4, count: 32), id = UUID()
        let partial = try CloudSnapshotProjection.project(source(), sourceID: id, level: .partial, key: key)
        let full = try CloudSnapshotProjection.project(source(), sourceID: id, level: .full, key: key)
        #expect(partial.title == "Private appointment")
        #expect(partial.location == nil && partial.notes == nil)
        #expect(full.location == "Private address" && full.notes == "Private notes")
        #expect(partial.id == full.id)
    }
    @Test func sourceIdentitiesAreStableButAccountScoped() {
        let a = CloudSnapshotProjection.opaqueUUID("source|event", key: Data(repeating: 1, count: 32))
        let b = CloudSnapshotProjection.opaqueUUID("source|event", key: Data(repeating: 1, count: 32))
        let c = CloudSnapshotProjection.opaqueUUID("source|event", key: Data(repeating: 2, count: 32))
        #expect(a == b)
        #expect(a != c)
    }
    @Test func endpointMustBeHTTPSAndPreservesDeploymentPrefix() throws {
        let url = try CloudEndpointPolicy.validated(" https://EXAMPLE.COM/chronograph/ ")
        #expect(url.absoluteString == "https://example.com/chronograph")
        #expect(url.appendingPathComponent("v1").appendingPathComponent("sources").path == "/chronograph/v1/sources")
        for value in ["http://example.com", "https://user:password@example.com", "https://example.com?token=secret", "https://example.com#fragment"] {
            #expect(throws: (any Error).self) { try CloudEndpointPolicy.validated(value) }
        }
    }
    @Test func ISO8601FractionalDatesDecodeFromBackend() throws {
        let data = Data("""
        {"challenge_id":"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","nonce":"sample","expires_at":"2026-10-28T04:00:00.123456Z"}
        """.utf8)
        let value = try CloudJSON.decoder().decode(CloudChallenge.self, from: data)
        #expect(value.challengeId.uuidString == "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        #expect(value.expiresAt.timeIntervalSince1970 > 0)
    }
    @Test func calendarWindowUsesCalendarDaysAcrossDaylightSaving() {
        let zone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-03-08T16:00:00Z")!
        let window = CloudSnapshotProjection.window(now: now, timezone: zone)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        #expect(calendar.dateComponents([.day], from: window.start, to: window.end).day == 98)
        #expect(calendar.component(.hour, from: window.start) == 0)
        #expect(calendar.component(.hour, from: window.end) == 0)
    }
}

struct CloudProjectionOwnershipTests {
    private var baseline: CloudProjectionFingerprint {
        CloudProjectionFingerprint(title: "Meeting", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200),
            timezone: "Asia/Shanghai", availability: 0, isAllDay: false, notes: nil, location: nil,
            hasAlarms: false, hasRecurrenceRules: false, hasStructuredLocation: false, hasParticipants: false)
    }
    @Test func manualCalendarChangesPreventUpdateAndDeletion() {
        #expect(CloudProjectionOwnership.allowsChange(baseline: baseline, current: baseline))
        var edited = baseline; edited.notes = "User-owned note"
        #expect(!CloudProjectionOwnership.allowsChange(baseline: baseline, current: edited))
        edited = baseline; edited.location = "User-owned location"
        #expect(!CloudProjectionOwnership.allowsChange(baseline: baseline, current: edited))
        edited = baseline; edited.hasAlarms = true
        #expect(!CloudProjectionOwnership.allowsChange(baseline: baseline, current: edited))
        edited = baseline; edited.hasRecurrenceRules = true
        #expect(!CloudProjectionOwnership.allowsChange(baseline: baseline, current: edited))
        edited = baseline; edited.hasStructuredLocation = true
        #expect(!CloudProjectionOwnership.allowsChange(baseline: baseline, current: edited))
        edited = baseline; edited.isAllDay = true
        #expect(!CloudProjectionOwnership.allowsChange(baseline: baseline, current: edited))
        edited = baseline; edited.timezone = "Europe/London"
        #expect(!CloudProjectionOwnership.allowsChange(baseline: baseline, current: edited))
        edited = baseline; edited.availability = 1
        #expect(!CloudProjectionOwnership.allowsChange(baseline: baseline, current: edited))
    }
    @Test func legacyMappingsWithoutCompleteBaselineAreNeverModified() {
        #expect(!CloudProjectionOwnership.allowsChange(baseline: nil, current: baseline))
    }
}


struct CloudDeviceIdentityTests {
    @Test func deviceStorageIsStablePerAccountAndDeployment() throws {
        let first = try CloudDeviceIdentityPolicy.storageKey(endpoint: "https://example.com/chronograph", appleUserID: "private-apple-user-a")
        let same = try CloudDeviceIdentityPolicy.storageKey(endpoint: "https://EXAMPLE.COM/chronograph/", appleUserID: "private-apple-user-a")
        let otherAccount = try CloudDeviceIdentityPolicy.storageKey(endpoint: "https://example.com/chronograph", appleUserID: "private-apple-user-b")
        let otherDeployment = try CloudDeviceIdentityPolicy.storageKey(endpoint: "https://example.com/another-app", appleUserID: "private-apple-user-a")
        #expect(first == same)
        #expect(first != otherAccount)
        #expect(first != otherDeployment)
        #expect(!first.contains("private-apple-user-a"))
        #expect(throws: (any Error).self) { try CloudDeviceIdentityPolicy.storageKey(endpoint: "https://example.com", appleUserID: "") }
    }
}
