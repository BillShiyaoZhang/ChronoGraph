import Foundation
import Testing
@testable import ChronoGraph

struct CalendarDisplayGroupingTests {
    @Test func matchingAccountTitlesKeepDistinctSourceIdentitiesAndStableOrder() {
        let groups = CalendarDisplayGrouping.groups([
            .init(id: "second", title: "Work", sourceID: "account-b", sourceTitle: "iCloud"),
            .init(id: "first-b", title: "Work", sourceID: "account-a", sourceTitle: "iCloud"),
            .init(id: "first-a", title: "Personal", sourceID: "account-a", sourceTitle: "iCloud")
        ])
        #expect(groups.map(\.id) == ["account-a", "account-b"])
        #expect(groups.map(\.calendarIDs) == [["first-a", "first-b"], ["second"]])
        #expect(groups.map(\.duplicateTitleIndex) == [1, 2])
    }

    @Test func labelsUseOnlyKnownCalendarPropertiesWithoutInferringAReceivedShare() {
        #expect(CalendarDisplayGrouping.kind(isManaged: true, isSubscribed: true, allowsContentModifications: false) == .managedCopy)
        #expect(CalendarDisplayGrouping.kind(isManaged: false, isSubscribed: true, allowsContentModifications: false) == .subscription)
        #expect(CalendarDisplayGrouping.kind(isManaged: false, isSubscribed: false, allowsContentModifications: false) == .readOnly)
        #expect(CalendarDisplayGrouping.kind(isManaged: false, isSubscribed: false, allowsContentModifications: true) == .ordinary)
    }

    @Test func receivedCalendarsGroupByOwnerIdentityEvenWhenOwnerNamesMatch() {
        let firstOwner = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let secondOwner = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        func source(_ owner: UUID, _ name: String) -> CloudSharedSource {
            CloudSharedSource(id: UUID(), ownerId: owner, ownerName: "Alex", name: name, privacy: .opaque,
                              generation: 1, coverageStart: nil, coverageEnd: nil, lastSyncedAt: nil)
        }
        let groups = CloudReceivedCalendarGroup.groups([source(secondOwner, "Other"), source(firstOwner, "Work"), source(firstOwner, "Family")])
        #expect(groups.map(\.id) == [firstOwner, secondOwner])
        #expect(groups.map { $0.sources.map(\.name) } == [["Family", "Work"], ["Other"]])
    }

    @Test func removingAnOwnersLastCalendarPreservesOtherRowsIdentitiesAndOrder() {
        let firstOwner = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let secondOwner = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        func source(owner: UUID, ownerName: String, name: String) -> CloudSharedSource {
            CloudSharedSource(id: UUID(), ownerId: owner, ownerName: ownerName, name: name, privacy: .opaque,
                              generation: 1, coverageStart: nil, coverageEnd: nil, lastSyncedAt: nil)
        }
        let removed = source(owner: firstOwner, ownerName: "Alex", name: "Only calendar")
        let work = source(owner: secondOwner, ownerName: "Blair", name: "Work")
        let family = source(owner: secondOwner, ownerName: "Blair", name: "Family")
        let sources = [work, removed, family]
        let before = CloudReceivedCalendarRow.rows(sources).map(\.id)
        let after = CloudReceivedCalendarRow.rows(sources.filter { $0.id != removed.id }).map(\.id)
        #expect(before == [.owner(firstOwner), .calendar(removed.id), .owner(secondOwner), .calendar(family.id), .calendar(work.id)])
        #expect(after == [.owner(secondOwner), .calendar(family.id), .calendar(work.id)])
        #expect(after == before.filter { $0 != .owner(firstOwner) && $0 != .calendar(removed.id) })
    }

    @Test func ownerAndCalendarIDsCannotCollideAndTheLastRemovalLeavesNoHeading() {
        let sharedID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let source = CloudSharedSource(id: sharedID, ownerId: sharedID, ownerName: "Alex", name: "Only calendar", privacy: .opaque,
                                       generation: 1, coverageStart: nil, coverageEnd: nil, lastSyncedAt: nil)
        let rows = CloudReceivedCalendarRow.rows([source])
        #expect(rows.map(\.id) == [.owner(sharedID), .calendar(sharedID)])
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(CloudReceivedCalendarRow.rows([source].filter { $0.id != sharedID }).isEmpty)
    }

}
