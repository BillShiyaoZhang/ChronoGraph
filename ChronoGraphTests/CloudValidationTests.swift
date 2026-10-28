import Foundation
import Testing
@testable import ChronoGraph

struct CloudWirePrecisionTests {
    private struct Dates: Codable { let start: Date; let end: Date }

    @Test func subsecondAndSubmillisecondEventsKeepPositiveWireIntervals() throws {
        let base = Date(timeIntervalSince1970: 1_793_242_800)
        for (start, end) in [(0.1, 0.9), (0.0001, 0.0009)] {
            let event = CloudBusyEvent(id: UUID(), seriesId: nil, start: base.addingTimeInterval(start),
                end: base.addingTimeInterval(end), isAllDay: false, timezone: "UTC", availability: "busy",
                title: nil, location: nil, notes: nil)
            let encoded = try CloudJSON.encoder().encode(event)
            let wire = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let a = try #require(wire["start"] as? String)
            let b = try #require(wire["end"] as? String)
            #expect(a != b)
            #expect(a.hasSuffix(start == 0.1 ? ".100000Z" : ".000100Z"))
            #expect(b.hasSuffix(end == 0.9 ? ".900000Z" : ".000900Z"))
            let decoded = try CloudJSON.decoder().decode(CloudBusyEvent.self, from: encoded)
            #expect(decoded.end > decoded.start)
            #expect(abs(decoded.start.timeIntervalSince(event.start)) < 0.000001)
            #expect(abs(decoded.end.timeIntervalSince(event.end)) < 0.000001)
        }
    }

    @Test func fractionalOffsetDatesDecodeWithoutLosingMicroseconds() throws {
        let wire = Data("""
        {"start":"2026-10-29T09:00:00.000100+05:30","end":"2026-10-29T09:00:00.000900+05:30"}
        """.utf8)
        let value = try CloudJSON.decoder().decode(Dates.self, from: wire)
        let base = try #require(ISO8601DateFormatter().date(from: "2026-10-29T03:30:00Z"))
        #expect(value.end > value.start)
        #expect(abs(value.start.timeIntervalSince(base) - 0.0001) < 0.000001)
        #expect(abs(value.end.timeIntervalSince(base) - 0.0009) < 0.000001)
    }

    @Test func negativeEpochAndSecondCarryRoundTripAtBackendPrecision() throws {
        for instant in [-0.000001, -0.5, 0, 1_793_242_800.9999996] {
            let date = Date(timeIntervalSince1970: instant)
            let data = try CloudJSON.encoder().encode(Dates(start: date, end: date.addingTimeInterval(1)))
            let result = try CloudJSON.decoder().decode(Dates.self, from: data)
            #expect(abs(result.start.timeIntervalSince(CloudJSON.normalizedDate(date))) < 0.000001)
            #expect(result.end > result.start)
        }
    }

    @Test func unsupportedDatesThrowEncodingErrorsRatherThanTrapping() {
        for instant in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                        -62_135_596_801, 253_402_300_800] {
            let date = Date(timeIntervalSince1970: instant)
            #expect(throws: EncodingError.self) { try CloudJSON.encoder().encode(Dates(start: date, end: date)) }
        }
    }

    @Test func unrepresentableEventIntervalsFailBeforeUpload() {
        for epoch in [0.0, 1_793_242_800] {
            let start = Date(timeIntervalSince1970: epoch)
            let end = start.addingTimeInterval(0.0000001)
            #expect(end > start)
            #expect(CloudJSON.normalizedDate(start) == CloudJSON.normalizedDate(end))
            let event = SourceEventSnapshot(calendarID: "synthetic", calendarItemIdentifier: "synthetic", title: "Synthetic",
                startDate: start, endDate: end, timeZoneIdentifier: "UTC")
            do {
                _ = try CloudSnapshotProjection.project(event, sourceID: UUID(), level: .opaque, key: Data(repeating: 1, count: 32))
                Issue.record("An interval that collapses at server precision must fail before uploading")
            } catch CloudClientError.invalidEventTime {
            } catch {
                Issue.record("Unexpected error type")
            }
        }
    }
}

struct CloudValidationFeedbackTests {
    private func response(_ issues: [[String: Any]], code: String = "invalid_request") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["detail": ["code": code, "message": "PRIVATE_SERVER_MESSAGE",
            "issues": issues, "input": "PRIVATE_CREDENTIAL"]])
    }

    @Test func safeEventFieldAndIndexExplainThe422WithoutEchoingContent() throws {
        let data = try response([["loc": ["body", "events", 2, "timezone"], "type": "value_error",
            "msg": "PRIVATE_EVENT_TITLE", "input": "PRIVATE_LOCATION", "ctx": ["error": "PRIVATE_NOTES"]]])
        let message = CloudValidationFeedback.message(from: data)
        #expect(message.contains("第3条日程的时区"))
        #expect(!message.contains("PRIVATE"))
    }

    @Test func knownLimitsAndIntervalErrorsAreUsefulAndRemainBounded() throws {
        let data = try response([
            ["loc": ["body", "events", 0, "title"], "type": "string_too_long"],
            ["loc": ["body", "events", 0, "title"], "type": "string_too_long"],
            ["loc": ["body", "events", 3], "type": "value_error"],
            ["loc": ["body", "name"], "type": "string_too_long"],
            ["loc": ["body", "password"], "type": "missing"]])
        let message = CloudValidationFeedback.message(from: data)
        #expect(message.contains("第1条日程的标题超过500个字符"))
        #expect(message.contains("第4条日程的结束时间必须晚于开始时间"))
        #expect(message.contains("日历名称超过120个字符"))
        #expect(!message.contains("密码"))
        #expect(message.components(separatedBy: "；").count == 3)
    }

    @Test func unknownPathsTypesAndIndicesNeverBecomeDisplayedText() throws {
        for issue: [String: Any] in [
            ["loc": ["body", "PRIVATE_EVENT_TITLE"], "type": "missing"],
            ["loc": ["body", "events", -1, "notes"], "type": "value_error"],
            ["loc": ["body", "events", Int.max, "notes"], "type": "value_error"],
            ["loc": ["body", "events", true, "notes"], "type": "value_error"],
            ["loc": ["body", "events", 0, "notes"], "type": "PRIVATE_ERROR_TYPE"]
        ] {
            let message = CloudValidationFeedback.message(from: try response([issue]))
            #expect(message == CloudValidationFeedback.fallback)
            #expect(!message.contains("PRIVATE"))
        }
        #expect(CloudValidationFeedback.message(from: Data("<html>PRIVATE</html>".utf8)) == CloudValidationFeedback.fallback)
    }

    @Test func modelAndPermissionFailuresUseFixedMessages() throws {
        let model = CloudValidationFeedback.message(from: try response([["loc": ["body"], "type": "value_error",
            "msg": "PRIVATE_CALENDAR_NAME", "input": "PRIVATE_PASSWORD"]]))
        #expect(model.contains("日期范围") && model.contains("重复标识"))
        #expect(!model.contains("PRIVATE"))
        let permission = CloudValidationFeedback.message(from: try response([], code: "upload_scope_violation"))
        #expect(permission.contains("授权范围"))
        #expect(!permission.contains("PRIVATE"))
    }
}
