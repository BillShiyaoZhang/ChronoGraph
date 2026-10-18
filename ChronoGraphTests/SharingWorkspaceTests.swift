import Foundation
import Testing
@testable import ChronoGraph

@MainActor
struct SharingWorkspaceTests {
    private func profile(name: String = "Work") -> SharedCalendarProfile {
        SharedCalendarProfile(name: name, sourceCalendarIDs: ["source"], targetSourceID: "icloud", privacyMode: .opaque)
    }

    @Test func browseAndRuleDraftsRemainIndependentPerProfileAndKeepTheirBaseRevision() throws {
        let workspace = SharingWorkspace(defaults: nil)
        let first = profile()
        let second = profile(name: "Family")
        let initial = workspace.browse(profileID: first.id, defaultProfile: first)
        #expect(initial.range == first.range && initial.sourceCalendarIDs == first.sourceCalendarIDs)
        #expect(initial.displayMode == nil)
        let browsing = ShareBrowseSettings(range: .rolling(pastDays: 30, futureDays: 365),
                                           sourceCalendarIDs: ["source", "other"], displayMode: .full)
        workspace.setBrowse(browsing, for: first.id)
        #expect(workspace.browse(profileID: first.id, defaultProfile: first) == browsing)
        #expect(workspace.browse(profileID: second.id, defaultProfile: second).displayMode == nil)
        #expect(workspace.drafts.isEmpty)
        var edited = first
        edited.privacyMode = .full
        workspace.saveDraft(profile: edited)
        edited.revision = 9
        edited.name = "Unpublished name"
        workspace.saveDraft(profile: edited)
        #expect(workspace.draft(profileID: first.id)?.baseRevision == first.revision)
        #expect(workspace.draft(profileID: first.id)?.profile.revision == first.revision)
        #expect(workspace.draft(profileID: second.id) == nil)
        workspace.resetBrowse(profile: first)
        #expect(workspace.browse(profileID: first.id, defaultProfile: first) == initial)
        #expect(workspace.draft(profileID: first.id)?.profile.name == "Unpublished name")
    }

    @Test func eventDraftPersistenceSeparatesProfilesOccurrencesAndInheritance() throws {
        let suiteName = "ChronoGraph.workspace.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = SharingWorkspace(defaults: defaults)
        let first = profile()
        let second = profile(name: "Family")
        let identity = UUID()
        let firstDraft = SharedEventVisibilityDraft(profileID: first.id, identityID: identity,
            occurrenceKey: "instant:one", entireSeries: true, visibility: .full, baseRevision: 3)
        let secondOccurrence = SharedEventVisibilityDraft(profileID: first.id, identityID: identity,
            occurrenceKey: "instant:two", visibility: nil, baseRevision: 3)
        let otherProfile = SharedEventVisibilityDraft(profileID: second.id, identityID: identity,
            occurrenceKey: "instant:one", visibility: .excluded, baseRevision: 8)
        workspace.saveEventDraft(firstDraft)
        workspace.saveEventDraft(secondOccurrence)
        workspace.saveEventDraft(otherProfile)
        let reloaded = SharingWorkspace(defaults: defaults)
        #expect(reloaded.eventDraft(profileID: first.id, identityID: identity, occurrenceKey: "instant:one") == firstDraft)
        #expect(reloaded.eventDraft(profileID: first.id, identityID: identity, occurrenceKey: "instant:two") == secondOccurrence)
        #expect(reloaded.eventDraft(profileID: second.id, identityID: identity, occurrenceKey: "instant:one") == otherProfile)
        reloaded.discardEventDraft(profileID: first.id, identityID: identity, occurrenceKey: "instant:one")
        #expect(reloaded.eventDraft(profileID: first.id, identityID: identity, occurrenceKey: "instant:one") == nil)
        #expect(reloaded.eventDraft(profileID: first.id, identityID: identity, occurrenceKey: "instant:two") != nil)
        #expect(reloaded.eventDraft(profileID: second.id, identityID: identity, occurrenceKey: "instant:one") != nil)
    }

    @Test func creationDraftIDAndPersonalBrowseSurviveReloadThenRotateOnDiscard() throws {
        let suiteName = "ChronoGraph.workspace.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = SharingWorkspace(defaults: defaults)
        let creationID = workspace.newDraftID
        var creation = profile(name: "Unpublished calendar")
        creation.id = creationID
        workspace.saveDraft(profile: creation)
        workspace.personalRange = .rolling(pastDays: 0, futureDays: 14)
        let reloaded = SharingWorkspace(defaults: defaults)
        #expect(reloaded.newDraftID == creationID)
        #expect(reloaded.draft(profileID: creationID)?.profile == creation)
        #expect(reloaded.personalRange == workspace.personalRange)
        reloaded.discardDraft(profileID: creationID)
        #expect(reloaded.newDraftID != creationID)
        #expect(reloaded.draft(profileID: creationID) == nil)
        let third = SharingWorkspace(defaults: defaults)
        #expect(third.newDraftID == reloaded.newDraftID)
    }
}
