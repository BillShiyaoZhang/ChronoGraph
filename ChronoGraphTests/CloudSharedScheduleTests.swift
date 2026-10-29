import Foundation
import Testing
@testable import ChronoGraph

@MainActor
struct CloudSharedScheduleTests {
    private let base = Date(timeIntervalSince1970: 1_793_232_000)
    private let sourceID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private let secondSourceID = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
    private let eventID = UUID(uuidString: "40000000-0000-4000-8000-000000000001")!
    private func source(_ privacy: CloudUploadLevel = .opaque, id: UUID? = nil,
                        start: Date? = nil, end: Date? = nil, updated: Date? = nil) -> CloudSharedSource {
        CloudSharedSource(id: id ?? sourceID,
            ownerId: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            ownerName: "Test friend", name: "Test calendar", privacy: privacy, generation: 1,
            coverageStart: start ?? base, coverageEnd: end ?? base.addingTimeInterval(4 * 86400),
            lastSyncedAt: updated ?? base)
    }
    private func event(start: Date? = nil, end: Date? = nil) -> CloudBusyEvent {
        CloudBusyEvent(id: eventID, seriesId: nil, start: start ?? base.addingTimeInterval(3600),
            end: end ?? base.addingTimeInterval(7200), isAllDay: false, timezone: "Asia/Shanghai",
            availability: "busy", title: "Forbidden unless granted", location: "Private room", notes: "Private note")
    }
    private var interval: DateInterval { DateInterval(start: base, duration: 86400) }

    @Test func projectionNeverExceedsTheGrantedFields() throws {
        let opaque = try #require(CloudSharedScheduleStore.project([event()], source: source(.opaque), interval: interval).first)
        #expect(opaque.title == CalendarEvent.Availability.busy.localizedName)
        #expect(opaque.location == nil && opaque.notes == nil)
        #expect(opaque.sourceDisplayName == "Test friend · Test calendar" && opaque.isReadOnly)
        let partial = try #require(CloudSharedScheduleStore.project([event()], source: source(.partial), interval: interval).first)
        #expect(partial.title == "Forbidden unless granted")
        #expect(partial.location == nil && partial.notes == nil)
        let full = try #require(CloudSharedScheduleStore.project([event()], source: source(.full), interval: interval).first)
        #expect(full.location == "Private room" && full.notes == "Private note")
    }

    @Test func individualEventRulesNarrowAFullCalendarGrant() throws {
        var value = event()
        value.visibility = .opaque
        let opaque = try #require(CloudSharedScheduleStore.project([value], source: source(.full), interval: interval).first)
        #expect(opaque.title == CalendarEvent.Availability.busy.localizedName)
        #expect(opaque.location == nil && opaque.notes == nil)
        value.visibility = .partial
        let partial = try #require(CloudSharedScheduleStore.project([value], source: source(.full), interval: interval).first)
        #expect(partial.title == value.title && partial.location == nil && partial.notes == nil)
    }

    @Test func individualEventRulesCannotExpandANarrowerCalendarGrant() throws {
        var value = event()
        value.visibility = .full
        let opaque = try #require(CloudSharedScheduleStore.project([value], source: source(.opaque), interval: interval).first)
        #expect(opaque.title == CalendarEvent.Availability.busy.localizedName && opaque.notes == nil)
        let partial = try #require(CloudSharedScheduleStore.project([value], source: source(.partial), interval: interval).first)
        #expect(partial.title == value.title && partial.location == nil && partial.notes == nil)
    }

    @Test func eventIdentityIncludesSourceAndOutsideOrDuplicateRowsAreRejected() throws {
        let a = try #require(CloudSharedScheduleStore.project([event(), event()], source: source(), interval: interval).first)
        let b = try #require(CloudSharedScheduleStore.project([event()], source: source(id: secondSourceID), interval: interval).first)
        #expect(a.id != b.id)
        #expect(CloudSharedScheduleStore.project([event(), event()], source: source(), interval: interval).count == 1)
        let outside = event(start: interval.end, end: interval.end.addingTimeInterval(3600))
        let invalid = event(start: base.addingTimeInterval(7200), end: base.addingTimeInterval(3600))
        #expect(CloudSharedScheduleStore.project([outside, invalid], source: source(), interval: interval).isEmpty)
    }

    @Test func partialCoverageFetchesOnlyItsIntersectionAndMarksUnknownDates() async {
        let store = CloudSharedScheduleStore()
        let shared = source(start: base.addingTimeInterval(3600), end: base.addingTimeInterval(7200))
        store.updateContext(scope: "server.account", sources: [shared])
        var requested: DateInterval?
        await store.load(selectedSourceIDs: [sourceID], interval: interval, now: base) { _, value in
            requested = value
            return [event()]
        }
        #expect(requested == DateInterval(start: base.addingTimeInterval(3600), end: base.addingTimeInterval(7200)))
        #expect(store.events.count == 1)
        #expect(store.issues.map(\.kind) == [.partialCoverage])
        #expect(!store.isLoading)
        #expect(store.loadedSourceIDs == [sourceID] && store.loadedInterval == interval)
    }

    @Test func missingCoverageAndUnknownSelectionsNeverTriggerUnauthorizedOrOutOfRangeFetch() async {
        let store = CloudSharedScheduleStore()
        store.updateContext(scope: "server.account", sources: [source()])
        var count = 0
        await store.load(selectedSourceIDs: [sourceID, secondSourceID],
                         interval: DateInterval(start: base.addingTimeInterval(-86400), duration: 3600), now: base) { _, _ in
            count += 1; return [event()]
        }
        #expect(count == 0 && store.events.isEmpty)
        #expect(store.issues.map(\.kind) == [.missingCoverage])
    }

    @Test func staleUploadsRemainBrowsableWithAnExplicitWarning() async {
        let store = CloudSharedScheduleStore()
        store.updateContext(scope: "server.account", sources: [source()])
        await store.load(selectedSourceIDs: [sourceID], interval: interval,
                         now: base.addingTimeInterval(86401)) { _, _ in [event()] }
        #expect(store.events.count == 1)
        #expect(store.issues.map(\.kind) == [.stale])
    }

    @Test func failedRefreshRemovesPreviousRowsInsteadOfPresentingThemAsCurrent() async {
        let store = CloudSharedScheduleStore()
        store.updateContext(scope: "server.account", sources: [source()])
        await store.load(selectedSourceIDs: [sourceID], interval: interval, now: base) { _, _ in [event()] }
        #expect(store.events.count == 1)
        await store.load(selectedSourceIDs: [sourceID], interval: interval, now: base) { _, _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(store.events.isEmpty && store.issues.map(\.kind) == [.offline])
    }

    @Test func revokedGrantAndExpiredSessionHaveDifferentRecoveryStates() async {
        let store = CloudSharedScheduleStore()
        store.updateContext(scope: "server.account", sources: [source()])
        await store.load(selectedSourceIDs: [sourceID], interval: interval, now: base) { _, _ in
            throw CloudClientError.http(404, "Source is unavailable")
        }
        #expect(store.events.isEmpty && store.issues.map(\.kind) == [.unavailable])
        store.updateContext(scope: "server.account", sources: [source(), source(id: secondSourceID)])
        await store.load(selectedSourceIDs: [sourceID, secondSourceID], interval: interval, now: base) { selected, _ in
            if selected.id == sourceID { return [event()] }
            throw CloudClientError.http(401, "Session expired")
        }
        #expect(store.events.isEmpty && store.issues.map(\.kind) == [.signInRequired])
        #expect(!store.isLoading)
        await store.load(selectedSourceIDs: [sourceID], interval: interval, now: base) { _, _ in
            throw CloudClientError.signIn
        }
        #expect(store.events.isEmpty && store.issues.map(\.kind) == [.signInRequired])
    }

    @Test func privacyDowngradeRevocationAndLogoutImmediatelyDiscardRenderedFields() async {
        let store = CloudSharedScheduleStore()
        store.updateContext(scope: "server.account", sources: [source(.full)])
        await store.load(selectedSourceIDs: [sourceID], interval: interval, now: base) { _, _ in [event()] }
        #expect(store.events.first?.notes == "Private note")
        #expect(store.matchesContext(scope: "server.account", sources: [source(.full)]))
        // Gate rendering before the SwiftUI updateContext callback has run.
        #expect(!store.matchesContext(scope: "server.account", sources: [source(.opaque)]))
        #expect(!store.matchesContext(scope: "server.other-account", sources: [source(.full)]))
        store.updateContext(scope: "server.account", sources: [source(.opaque)])
        #expect(store.events.isEmpty && store.loadedSourceIDs.isEmpty && store.loadedInterval == nil)
        await store.load(selectedSourceIDs: [sourceID], interval: interval, now: base) { _, _ in [event()] }
        #expect(store.events.first?.notes == nil)
        store.updateContext(scope: "server.account", sources: [])
        #expect(store.events.isEmpty)
        store.updateContext(scope: nil, sources: [source(.full)])
        #expect(store.contextScope == nil && store.events.isEmpty && store.loadedSourceIDs.isEmpty && store.loadedInterval == nil)
    }

    @Test func aSuspendedRequestCannotRepopulateAnotherAccountOrLoggedOutScreen() async {
        let store = CloudSharedScheduleStore()
        store.updateContext(scope: "server.accountA", sources: [source(.full)])
        var suspended: CheckedContinuation<[CloudBusyEvent], Never>?
        let request = Task { @MainActor in
            await store.load(selectedSourceIDs: [sourceID], interval: interval, now: base) { _, _ in
                await withCheckedContinuation { suspended = $0 }
            }
        }
        while suspended == nil { await Task.yield() }
        store.updateContext(scope: "server.accountB", sources: [source()])
        suspended?.resume(returning: [event()])
        await request.value
        #expect(store.contextScope == "server.accountB" && store.events.isEmpty && store.issues.isEmpty && !store.isLoading)
        #expect(store.loadedSourceIDs.isEmpty && store.loadedInterval == nil)
        store.reset()
        #expect(store.contextScope == nil && store.events.isEmpty)
    }

    @Test func slowerPreviousDateRequestCannotOverwriteTheNewRange() async {
        let store = CloudSharedScheduleStore()
        store.updateContext(scope: "server.account", sources: [source()])
        var suspended: CheckedContinuation<[CloudBusyEvent], Never>?
        let oldRequest = Task { @MainActor in
            await store.load(selectedSourceIDs: [sourceID], interval: interval, now: base) { _, _ in
                await withCheckedContinuation { suspended = $0 }
            }
        }
        while suspended == nil { await Task.yield() }
        let later = DateInterval(start: base.addingTimeInterval(86400), duration: 86400)
        await store.load(selectedSourceIDs: [sourceID], interval: later, now: base) { _, _ in
            [event(start: later.start.addingTimeInterval(3600), end: later.start.addingTimeInterval(7200))]
        }
        let expected = store.events.first?.startDate
        suspended?.resume(returning: [event()])
        await oldRequest.value
        #expect(store.events.count == 1 && store.events.first?.startDate == expected)
        #expect(expected == later.start.addingTimeInterval(3600))
        #expect(store.loadedSourceIDs == [sourceID] && store.loadedInterval == later)
    }

    @Test func loadCompletionMarkersStayEmptyWhileTheNewDateRangeIsPending() async {
        let store = CloudSharedScheduleStore()
        store.updateContext(scope: "server.account", sources: [source(), source(id: secondSourceID)])
        #expect(store.matchesContext(scope: "server.account", sources: [source(id: secondSourceID), source()]))
        await store.load(selectedSourceIDs: [sourceID], interval: interval, now: base) { _, _ in [] }
        #expect(store.loadedSourceIDs == [sourceID] && store.loadedInterval == interval)
        let later = DateInterval(start: base.addingTimeInterval(86400), duration: 86400)
        var suspended: CheckedContinuation<[CloudBusyEvent], Never>?
        let request = Task { @MainActor in
            await store.load(selectedSourceIDs: [sourceID], interval: later, now: base) { _, _ in
                await withCheckedContinuation { suspended = $0 }
            }
        }
        while suspended == nil { await Task.yield() }
        #expect(store.isLoading && store.loadedSourceIDs.isEmpty && store.loadedInterval == nil)
        suspended?.resume(returning: [])
        await request.value
        #expect(!store.isLoading && store.loadedSourceIDs == [sourceID] && store.loadedInterval == later)
        store.reset()
        #expect(store.loadedSourceIDs.isEmpty && store.loadedInterval == nil)
    }
}
