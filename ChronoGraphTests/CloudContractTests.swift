import Foundation
import Testing
@testable import ChronoGraph

/// Offline contract fixtures use the server's documented wire names, not the iOS encoder.
/// No network, Calendar store, Keychain or signed-in account is accessed here.
struct CloudContractTests {
    private let account = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let device = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let sourceID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private let eventID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!

    private func data(_ value: String) -> Data { Data(value.utf8) }
    private func instant(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: CloudJSON.encoder().encode(value)) as? [String: Any])
    }
    private func original() -> SourceEventSnapshot {
        SourceEventSnapshot(calendarID: "local-calendar", calendarItemIdentifier: "local-event",
            title: "Planning", startDate: instant("2026-10-29T01:00:00Z"), endDate: instant("2026-10-29T02:00:00Z"),
            location: "Room", notes: "Notes", timeZoneIdentifier: "Asia/Shanghai", readTimeZoneIdentifier: "Asia/Shanghai")
    }

    @Test func sessionResponseAndSecureCacheRoundTripUseTheBackendContract() throws {
        let wire = data("""
        {"access_token":"synthetic-session-token","token_type":"bearer","expires_at":"2026-11-28T04:00:00.123456+00:00",
         "user":{"id":"10000000-0000-4000-8000-000000000001","display_name":"林晓"},
         "device_id":"20000000-0000-4000-8000-000000000001"}
        """)
        let session = try CloudJSON.decoder().decode(CloudSession.self, from: wire)
        #expect(session.user.id == account && session.deviceId == device)
        #expect(session.user.displayName == "林晓" && session.tokenType == "bearer")
        #expect(abs(session.expiresAt.timeIntervalSince(instant("2026-11-28T04:00:00Z")) - 0.123456) < 0.001)
        let stored = try CloudJSON.encoder().encode(session)
        let restored = try CloudJSON.decoder().decode(CloudSession.self, from: stored)
        #expect(restored.accessToken == session.accessToken && restored.user.id == session.user.id)
        let keys = try object(session)
        #expect(keys["access_token"] as? String == "synthetic-session-token")
        #expect(keys["device_id"] as? String == device.uuidString)
        #expect(keys["accessToken"] == nil && keys["deviceId"] == nil)
    }

    @Test func newSourceAcceptsNullCoverageButNeverInventsCoverage() throws {
        let value = try CloudJSON.decoder().decode(CloudSource.self, from: data("""
        {"id":"30000000-0000-4000-8000-000000000001","owner_id":"10000000-0000-4000-8000-000000000001",
         "device_id":"20000000-0000-4000-8000-000000000001","name":"工作","upload_level":"opaque","generation":0,
         "coverage_start":null,"coverage_end":null,"last_synced_at":null}
        """))
        #expect(value.id == sourceID && value.ownerId == account && value.deviceId == device)
        #expect(value.uploadLevel == .opaque && value.generation == 0)
        #expect(value.coverageStart == nil && value.coverageEnd == nil && value.lastSyncedAt == nil)
    }

    @Test func sharedSourceRetainsOwnerPrivacyAndOffsetTimes() throws {
        let value = try CloudJSON.decoder().decode(CloudSharedSource.self, from: data("""
        {"id":"30000000-0000-4000-8000-000000000001","owner_id":"10000000-0000-4000-8000-000000000001",
         "owner_name":"林晓","name":"工作","privacy":"partial","generation":7,
         "coverage_start":"2026-10-29T00:00:00+08:00","coverage_end":"2026-10-30T00:00:00+08:00",
         "last_synced_at":"2026-10-28T04:00:00.250000Z"}
        """))
        #expect(value.ownerName == "林晓" && value.privacy == .partial && value.generation == 7)
        #expect(value.coverageStart == instant("2026-10-28T16:00:00Z"))
        #expect(value.coverageEnd == instant("2026-10-29T16:00:00Z"))
    }

    @Test func availabilityKeepsContinuousWindowSeparateFromFixedDurationSuggestion() throws {
        let value = try CloudJSON.decoder().decode(CloudAvailability.self, from: data("""
        {"timezone":"Asia/Shanghai","checked_at":"2026-10-28T04:00:00Z",
         "windows":[{"start":"2026-10-29T02:00:00Z","end":"2026-10-29T05:30:00Z",
                      "suggested_start":"2026-10-29T02:00:00Z","suggested_end":"2026-10-29T03:00:00Z"}],
         "sources":[{"id":"30000000-0000-4000-8000-000000000001","generation":7,"last_synced_at":"2026-10-28T04:00:00Z"}]}
        """))
        let slot = try #require(value.windows.first)
        #expect(value.timezone == "Asia/Shanghai")
        #expect(slot.end.timeIntervalSince(slot.start) == 3.5 * 3600)
        #expect(slot.suggestedEnd.timeIntervalSince(slot.suggestedStart) == 3600)
        #expect(slot.id == slot.suggestedStart)
    }

    @Test func emptyAvailabilityIsDifferentFromMalformedAvailability() throws {
        let value = try CloudJSON.decoder().decode(CloudAvailability.self, from: data("""
        {"timezone":"UTC","checked_at":"2026-10-28T04:00:00Z","windows":[],"sources":[]}
        """))
        #expect(value.windows.isEmpty)
        #expect(throws: DecodingError.self) {
            try CloudJSON.decoder().decode(CloudAvailability.self, from: data("""
            {"timezone":"UTC","checked_at":"2026-10-28T04:00:00Z"}
            """))
        }
    }

    @Test func meetingResponsePreservesRevisionAndEachPersonsResponse() throws {
        let value = try CloudJSON.decoder().decode(CloudMeeting.self, from: data("""
        {"id":"50000000-0000-4000-8000-000000000001","host_id":"10000000-0000-4000-8000-000000000001",
         "title":"一起找时间","start":"2026-10-29T01:00:00Z","end":"2026-10-29T02:00:00Z",
         "timezone":"Asia/Shanghai","revision":3,"status":"proposed","updated_at":"2026-10-28T04:00:00.000001Z",
         "participants":[{"user_id":"10000000-0000-4000-8000-000000000001","response":"accepted"},
                         {"user_id":"10000000-0000-4000-8000-000000000002","response":"tentative"}]}
        """))
        #expect(value.hostId == account && value.revision == 3 && value.status == "proposed")
        #expect(value.participants.count == 2)
        #expect(value.participants[0].userId == account && value.participants[0].response == "accepted")
        #expect(value.participants[1].response == "tentative")
    }

    @Test func deviceTaskDecodesWithoutTrustingItsHistoricalProjectionPayload() throws {
        let tasks = try CloudJSON.decoder().decode([CloudDeviceTask].self, from: data("""
        [{"id":"60000000-0000-4000-8000-000000000001","meeting_id":"50000000-0000-4000-8000-000000000001",
          "revision":3,"action":"delete","created_at":"2026-10-28T04:00:00Z",
          "payload":{"title":"Superseded title","revision":2,"start":"2026-10-29T01:00:00Z"}}]
        """))
        let task = try #require(tasks.first)
        #expect(task.meetingId == UUID(uuidString: "50000000-0000-4000-8000-000000000001"))
        #expect(task.revision == 3 && task.action == "delete")
    }

    @Test func pairingAndFeedLinksDecodeURLsWithTheDeploymentPrefix() throws {
        let pair = try CloudJSON.decoder().decode(CloudShareLink.self, from: data("""
        {"id":"70000000-0000-4000-8000-000000000001","token":"synthetic-pair-token",
         "join_url":"https://example.invalid/chronograph/join/synthetic-pair-token","expires_at":"2026-11-28T04:00:00Z"}
        """))
        let feed = try CloudJSON.decoder().decode(CloudFeedLink.self, from: data("""
        {"id":"70000000-0000-4000-8000-000000000002","url":"https://example.invalid/chronograph/v1/feeds/synthetic-feed.ics",
         "expires_at":"2026-11-28T04:00:00Z"}
        """))
        #expect(pair.joinUrl.path == "/chronograph/join/synthetic-pair-token")
        #expect(pair.joinUrl.lastPathComponent == pair.token)
        #expect(feed.url.path == "/chronograph/v1/feeds/synthetic-feed.ics")
    }

    @Test func accessRecordsDistinguishGrantRecipientFromRevocableLinkID() throws {
        let grant = try CloudJSON.decoder().decode(CloudAccessRecord.self, from: data("""
        {"user_id":"10000000-0000-4000-8000-000000000001","privacy":"opaque"}
        """))
        let link = try CloudJSON.decoder().decode(CloudAccessRecord.self, from: data("""
        {"id":"70000000-0000-4000-8000-000000000001","privacy":"full","expires_at":"2026-11-28T04:00:00Z","revoked":true,"redeemed_by":null}
        """))
        #expect(grant.id == nil && grant.identifier == account)
        #expect(link.identifier == link.id && link.revoked == true && link.privacy == .full)
    }

    @Test func snapshotWireUsesSnakeCaseAndOmitsDisallowedOpaqueFields() throws {
        var source = original()
        source.isAllDay = true
        source.availability = .notSupported
        source.timeZoneIdentifier = nil
        let projected = try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .opaque, key: Data(repeating: 1, count: 32))
        let snapshot = CloudSnapshot(snapshotId: eventID, expectedGeneration: 9, windowStart: instant("2026-10-28T00:00:00Z"),
            windowEnd: instant("2026-10-30T00:00:00Z"), events: [projected])
        let wire = try object(snapshot)
        #expect(Set(wire.keys) == ["snapshot_id", "expected_generation", "window_start", "window_end", "events"])
        #expect(wire["expected_generation"] as? Int == 9)
        let event = try #require((wire["events"] as? [[String: Any]])?.first)
        #expect(event["is_all_day"] as? Bool == true && event["availability"] as? String == "unknown")
        #expect(event["timezone"] as? String == "Asia/Shanghai")
        #expect(event["series_id"] == nil && event["title"] == nil && event["location"] == nil && event["notes"] == nil)
    }

    @Test func eventVisibilityIsBackwardCompatibleAndEncodedExplicitlyForNewSnapshots() throws {
        let legacy = data("""
        {"id":"40000000-0000-4000-8000-000000000001","start":"2026-10-29T01:00:00Z","end":"2026-10-29T02:00:00Z",
         "is_all_day":false,"timezone":"Asia/Shanghai","availability":"busy"}
        """)
        let decoded = try CloudJSON.decoder().decode(CloudBusyEvent.self, from: legacy)
        #expect(decoded.visibility == nil)
        let projected = try CloudSnapshotProjection.project(original(), sourceID: sourceID, level: .partial, key: Data(repeating: 1, count: 32))
        let wire = try object(projected)
        #expect(wire["visibility"] as? String == "partial")
        #expect(wire["title"] as? String == "Planning")
        #expect(wire["notes"] == nil && wire["location"] == nil)
        let restored = try CloudJSON.decoder().decode(CloudBusyEvent.self, from: CloudJSON.encoder().encode(projected))
        #expect(restored.visibility == .partial)
    }

    @Test func searchRequestUsesBackendPersonSourceSelectionAndLocalDailyTimes() throws {
        let people = [CloudParticipant(userId: account, sourceIds: [sourceID]),
                      CloudParticipant(userId: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
                                       sourceIds: [UUID(uuidString: "30000000-0000-4000-8000-000000000002")!])]
        let request = CloudAvailabilityRequest(participants: people,
            windowStart: instant("2026-10-29T00:00:00Z"), windowEnd: instant("2026-11-01T00:00:00Z"), durationMinutes: 90,
            timezone: "America/New_York", dailyStart: "09:30", dailyEnd: "17:45")
        let wire = try object(request)
        #expect(Set(wire.keys) == ["participants", "window_start", "window_end", "duration_minutes", "timezone", "daily_start", "daily_end"])
        #expect(wire["duration_minutes"] as? Int == 90 && wire["daily_start"] as? String == "09:30")
        let person = try #require((wire["participants"] as? [[String: Any]])?.first)
        #expect(person["user_id"] as? String == account.uuidString)
        #expect(person["source_ids"] as? [String] == [sourceID.uuidString])
    }

    @Test func meetingRetryRequestIDSurvivesEncodingAndPayloadComparison() throws {
        let people = [CloudParticipant(userId: account, sourceIds: [sourceID]),
                      CloudParticipant(userId: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
                                       sourceIds: [UUID(uuidString: "30000000-0000-4000-8000-000000000002")!])]
        let proposal = CloudCreateMeeting(requestId: eventID, title: "Planning", start: instant("2026-10-29T01:00:00Z"),
            end: instant("2026-10-29T02:00:00Z"), timezone: "Asia/Shanghai", participants: people)
        let retry = try CloudJSON.decoder().decode(CloudCreateMeeting.self, from: CloudJSON.encoder().encode(proposal))
        #expect(retry.requestId == proposal.requestId && retry.samePayload(as: proposal))
        #expect(try object(proposal)["request_id"] as? String == eventID.uuidString)
        var alternateID = proposal; alternateID.requestId = UUID()
        #expect(alternateID.samePayload(as: proposal))
        let changed = CloudCreateMeeting(requestId: proposal.requestId, title: proposal.title,
            start: proposal.start.addingTimeInterval(900), end: proposal.end.addingTimeInterval(900),
            timezone: proposal.timezone, participants: proposal.participants)
        #expect(!changed.samePayload(as: proposal))
    }

    @Test func malformedAuthAndUnzonedDatesFailInsteadOfInventingAccountOrTime() {
        for wire in [
            "{\"token_type\":\"bearer\",\"expires_at\":\"2026-11-28T04:00:00Z\"}",
            "{\"access_token\":\"x\",\"token_type\":\"bearer\",\"expires_at\":\"2026-11-28T04:00:00Z\",\"user\":{\"id\":\"bad-uuid\",\"display_name\":\"A\"},\"device_id\":\"20000000-0000-4000-8000-000000000001\"}"
        ] {
            #expect(throws: DecodingError.self) { try CloudJSON.decoder().decode(CloudSession.self, from: data(wire)) }
        }
        #expect(throws: DecodingError.self) {
            try CloudJSON.decoder().decode(CloudChallenge.self, from: data("""
            {"challenge_id":"10000000-0000-4000-8000-000000000001","nonce":"test","expires_at":"2026-10-29T09:00:00"}
            """))
        }
    }

    @Test func fullProjectionPreservesAllowedBoundaryLengthsWithoutAddingWireFields() throws {
        var source = original()
        source.title = String(repeating: "会", count: 500)
        source.location = String(repeating: "地", count: 1000)
        source.notes = String(repeating: "注", count: 10_000)
        let projected = try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .full, key: Data(repeating: 2, count: 32))
        #expect(projected.title == source.title && projected.location == source.location && projected.notes == source.notes)
        let wire = try object(projected)
        #expect(Set(wire.keys).isSubset(of: ["id", "series_id", "start", "end", "is_all_day", "timezone", "availability", "title", "location", "notes", "visibility"]))
        #expect(wire["calendar_id"] == nil && wire["event_identifier"] == nil && wire["url"] == nil)
    }

    @Test func selectedFieldOverflowsFailBeforeUploadWithoutLeakingPrivateText() throws {
        let cases: [(String, Int, (inout SourceEventSnapshot) -> Void)] = [
            ("标题", 500, { $0.title = "PRIVATE-TITLE" + String(repeating: "会", count: 501) }),
            ("地点", 1000, { $0.location = "PRIVATE-LOCATION" + String(repeating: "地", count: 1001) }),
            ("备注", 10_000, { $0.notes = "PRIVATE-NOTES" + String(repeating: "注", count: 10_001) })
        ]
        for (field, maximum, change) in cases {
            var source = original(); change(&source)
            do {
                _ = try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .full, key: Data(repeating: 9, count: 32))
                Issue.record("An oversized selected field must not enter a snapshot")
            } catch CloudClientError.uploadFieldLimit(let actualField, let actualMaximum) {
                #expect(actualField == field && actualMaximum == maximum)
                let description = CloudClientError.uploadFieldLimit(actualField, actualMaximum).localizedDescription
                #expect(!description.contains("PRIVATE-"))
            }
        }
    }

    @Test func composedUnicodeUsesTheServersCodePointLimitRatherThanGraphemeCount() throws {
        var source = original()
        source.title = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        #expect(source.title.count == 100 && source.title.unicodeScalars.count == 700)
        do {
            _ = try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .partial, key: Data(repeating: 10, count: 32))
            Issue.record("The server counts Unicode code points; a 700-code-point title is too long")
        } catch CloudClientError.uploadFieldLimit(let field, let maximum) {
            #expect(field == "标题" && maximum == 500)
        }
    }

    @Test func oversizedHiddenFieldsDoNotBlockAnOtherwiseValidBusyUpload() throws {
        var source = original()
        source.title = String(repeating: "会", count: 501)
        source.location = String(repeating: "地", count: 1001)
        source.notes = String(repeating: "注", count: 10_001)
        let opaque = try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .opaque, key: Data(repeating: 11, count: 32))
        #expect(opaque.title == nil && opaque.location == nil && opaque.notes == nil)
        source.title = "Allowed title"
        let partial = try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .partial, key: Data(repeating: 11, count: 32))
        #expect(partial.title == source.title && partial.location == nil && partial.notes == nil)
    }

    @Test func zeroAndReversedEventIntervalsFailBeforeSnapshotCreation() {
        var zero = original(); zero.endDate = zero.startDate
        var reversed = original(); reversed.endDate = reversed.startDate.addingTimeInterval(-1)
        for source in [zero, reversed] {
            do {
                _ = try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .opaque, key: Data(repeating: 12, count: 32))
                Issue.record("An invalid local interval must not enter the cloud snapshot")
            } catch CloudClientError.invalidEventTime {
                // Expected: do not turn an invalid source read into an apparently empty read.
            } catch {
                Issue.record("Unexpected validation error: \(error)")
            }
        }
    }

    @Test func nonFiniteEventDatesFailBeforeAnyDateEncoding() {
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            var source = original(); source.startDate = Date(timeIntervalSinceReferenceDate: value)
            do {
                _ = try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .opaque, key: Data(repeating: 13, count: 32))
                Issue.record("A non-finite calendar date must not enter a snapshot")
            } catch CloudClientError.invalidEventTime {
            } catch {
                Issue.record("Unexpected validation error: \(error)")
            }
        }
    }

    @Test func everyEventKitAvailabilityHasTheServerEquivalent() throws {
        let mapping: [(CalendarEvent.Availability, String)] = [(.busy, "busy"), (.free, "free"), (.tentative, "tentative"), (.unavailable, "unavailable"), (.notSupported, "unknown")]
        for (availability, expected) in mapping {
            var source = original(); source.availability = availability
            let projected = try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .opaque, key: Data(repeating: 3, count: 32))
            #expect(projected.availability == expected)
        }
    }

    @Test func recurringInstancesShareASeriesIDButReschedulingKeepsAnOccurrenceID() throws {
        var first = original()
        first.isRecurring = true
        first.occurrenceDate = first.startDate
        var moved = first
        moved.startDate = first.startDate.addingTimeInterval(3600)
        moved.endDate = first.endDate.addingTimeInterval(3600)
        var next = first
        next.occurrenceDate = first.startDate.addingTimeInterval(7 * 86400)
        next.startDate = next.occurrenceDate!
        next.endDate = first.endDate.addingTimeInterval(7 * 86400)
        let key = Data(repeating: 4, count: 32)
        let a = try CloudSnapshotProjection.project(first, sourceID: sourceID, level: .opaque, key: key)
        let b = try CloudSnapshotProjection.project(moved, sourceID: sourceID, level: .opaque, key: key)
        let c = try CloudSnapshotProjection.project(next, sourceID: sourceID, level: .opaque, key: key)
        #expect(a.seriesId != nil && a.seriesId == b.seriesId && a.seriesId == c.seriesId)
        #expect(a.id == b.id && a.id != c.id)
        #expect(b.start == moved.startDate)
    }

    @Test func allDayProjectionPreservesTheActualDSTDayInterval() throws {
        var source = original()
        source.isAllDay = true
        source.timeZoneIdentifier = "America/New_York"
        source.readTimeZoneIdentifier = "America/New_York"
        source.startDate = instant("2026-03-08T05:00:00Z")
        source.endDate = instant("2026-03-09T04:00:00Z")
        let projected = try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .opaque, key: Data(repeating: 5, count: 32))
        #expect(projected.isAllDay && projected.timezone == "America/New_York")
        #expect(projected.end.timeIntervalSince(projected.start) == 23 * 3600)
    }

    @Test func recurringEventWithoutOriginalOccurrenceCannotBecomeAnUnidentifiedUpload() {
        var source = original(); source.isRecurring = true; source.occurrenceDate = nil
        #expect(throws: SharedCalendarModelError.self) {
            try CloudSnapshotProjection.project(source, sourceID: sourceID, level: .opaque, key: Data(repeating: 6, count: 32))
        }
    }

    @Test func endpointCanonicalizationRetainsAnExplicitPortAndDeploymentPath() throws {
        let value = try CloudEndpointPolicy.validated("\n HTTPS://EXAMPLE.INVALID:8443/deployment/chronograph/// \t")
        #expect(value.absoluteString == "https://example.invalid:8443/deployment/chronograph")
        #expect(value.appendingPathComponent("v1").appendingPathComponent("meetings").path == "/deployment/chronograph/v1/meetings")
        for invalid in ["https://", "/chronograph", "example.invalid", "https://@example.invalid", "https://example.invalid?", "https://example.invalid#"] {
            #expect(throws: (any Error).self) { try CloudEndpointPolicy.validated(invalid) }
        }
    }

    @Test func changingTitleTimesOrParticipantsAlsoPreventsCalendarMutation() {
        let baseline = CloudProjectionFingerprint(title: "Meeting", start: instant("2026-10-29T01:00:00Z"), end: instant("2026-10-29T02:00:00Z"),
            timezone: "UTC", availability: 0, isAllDay: false, notes: nil, location: nil,
            hasAlarms: false, hasRecurrenceRules: false, hasStructuredLocation: false, hasParticipants: false)
        var edits: [CloudProjectionFingerprint] = []
        var edit = baseline; edit.title = "User title"; edits.append(edit)
        edit = baseline; edit.start = edit.start.addingTimeInterval(60); edits.append(edit)
        edit = baseline; edit.end = edit.end.addingTimeInterval(60); edits.append(edit)
        edit = baseline; edit.hasParticipants = true; edits.append(edit)
        for changed in edits { #expect(!CloudProjectionOwnership.allowsChange(baseline: baseline, current: changed)) }
    }
}
