import Foundation
import XCTest
@preconcurrency import EventKit
@testable import ChronoGraph

#if targetEnvironment(simulator)
/// Run only after revoking Calendar permission on a dedicated Simulator.
/// These checks do not request access, create a calendar, or access any event.
@MainActor
final class CloudCalendarPermissionIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CHRONOGRAPH_EXPECT_CALENDAR_DENIED"] == "1" else {
            throw XCTSkip("Calendar permission checks require an explicitly opted-in, dedicated Simulator with access revoked.")
        }
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-cloud-signed-in-fixtures"),
                       "Permission tests must use native Calendar access checks.")
        XCTAssertNotEqual(EKEventStore.authorizationStatus(for: .event), .fullAccess,
                          "Revoke Calendar permission on the dedicated Simulator before running these tests.")
    }

    func testNativeReaderInventoryRejectsMissingFullPermissionWithoutRequestingIt() async {
        let reader = CloudCalendarReader()
        await expectPermission {
            _ = try await reader.inventory()
        }
    }

    func testNativeReaderEventsRejectMissingFullPermissionWithoutQueryingCalendar() async {
        let reader = CloudCalendarReader()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        await expectPermission {
            _ = try await reader.events(calendarID: "synthetic-denied-" + UUID().uuidString,
                                        interval: DateInterval(start: start, duration: 3600))
        }
    }

    func testNativeWriterDestinationsRejectMissingFullPermissionWithoutRequestingIt() async {
        let writer = CloudMeetingCalendarWriter()
        await expectPermission {
            _ = try await writer.destinations()
        }
    }

    func testNativeWriterSaveRejectsMissingFullPermissionBeforeCreatingAnything() async {
        let writer = CloudMeetingCalendarWriter()
        let hostID = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let meeting = CloudMeeting(id: UUID(), hostId: hostID, title: "Synthetic denied-permission meeting",
                                   start: start, end: start.addingTimeInterval(3600), timezone: "Asia/Shanghai",
                                   revision: 1, status: "confirmed",
                                   participants: [CloudMeetingMember(userId: hostID, response: "accepted")], updatedAt: start)
        await expectPermission {
            try await writer.save(meeting, calendarID: "synthetic-denied-" + UUID().uuidString,
                                  namespace: "simulator-denied." + UUID().uuidString)
        }
    }

    private func expectPermission(file: StaticString = #filePath, line: UInt = #line,
                                  _ operation: () async throws -> Void) async {
        let before = EKEventStore.authorizationStatus(for: .event)
        XCTAssertNotEqual(before, .fullAccess, file: file, line: line)
        do {
            try await operation()
            XCTFail("Calendar access must fail before reading or writing without full permission.", file: file, line: line)
        } catch CloudClientError.permission { }
        catch { XCTFail("Unexpected permission error: \(error)", file: file, line: line) }
        XCTAssertEqual(EKEventStore.authorizationStatus(for: .event), before,
                       "A background reader or writer must not request Calendar permission.", file: file, line: line)
    }
}
#endif
