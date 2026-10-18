import Foundation
import Combine

struct ShareBrowseSettings: Codable, Equatable, Sendable {
    var range: SharedCalendarRange
    var sourceCalendarIDs: Set<String>
    /// Nil follows the confirmed sharing rules. A value affects local display only.
    var displayMode: PrivacyMode?

    init(range: SharedCalendarRange, sourceCalendarIDs: Set<String>, displayMode: PrivacyMode? = nil) {
        self.range = range
        self.sourceCalendarIDs = sourceCalendarIDs
        self.displayMode = displayMode
    }
}

struct SharedCalendarDraft: Codable, Identifiable, Equatable, Sendable {
    var baseRevision: Int
    var profile: SharedCalendarProfile
    var id: UUID { profile.id }

    init(baseRevision: Int, profile: SharedCalendarProfile) {
        self.baseRevision = baseRevision
        self.profile = profile
        self.profile.revision = baseRevision
    }

    init(profile: SharedCalendarProfile) { self.init(baseRevision: profile.revision, profile: profile) }
}

struct SharedEventVisibilityDraft: Codable, Equatable, Sendable {
    var profileID: UUID
    var identityID: UUID
    var occurrenceKey: String?
    var entireSeries: Bool
    /// Nil is a draft decision to restore inheritance, not the absence of a draft.
    var visibility: SharedVisibility?
    var baseRevision: Int

    init(profileID: UUID, identityID: UUID, occurrenceKey: String? = nil, entireSeries: Bool = false,
         visibility: SharedVisibility?, baseRevision: Int) {
        self.profileID = profileID
        self.identityID = identityID
        self.occurrenceKey = occurrenceKey
        self.entireSeries = entireSeries
        self.visibility = visibility
        self.baseRevision = baseRevision
    }
}

/// Configuration-only, local preferences. The background publisher never reads this workspace.
@MainActor
final class SharingWorkspace: ObservableObject {
    private struct StoredState: Codable {
        var browseSettings: [UUID: ShareBrowseSettings] = [:]
        var drafts: [UUID: SharedCalendarDraft] = [:]
        var eventDrafts: [String: SharedEventVisibilityDraft] = [:]
        var personalRange: SharedCalendarRange?
        var newDraftID = UUID()
    }

    private let defaults: UserDefaults?
    private let storageKey = "sharing.workspace.v1"
    @Published private(set) var browseSettings: [UUID: ShareBrowseSettings]
    @Published private(set) var drafts: [UUID: SharedCalendarDraft]
    @Published private(set) var eventDrafts: [String: SharedEventVisibilityDraft]
    @Published private(set) var newDraftID: UUID
    @Published private(set) var errorMessage: String?
    @Published var personalRange: SharedCalendarRange? { didSet { persist() } }

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let saved = defaults?.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(StoredState.self, from: $0) }
        let state = saved ?? StoredState()
        browseSettings = state.browseSettings
        drafts = state.drafts
        eventDrafts = state.eventDrafts
        newDraftID = state.newDraftID
        personalRange = state.personalRange
    }

    func browse(profileID: UUID, defaultProfile: SharedCalendarProfile) -> ShareBrowseSettings {
        browseSettings[profileID] ?? ShareBrowseSettings(range: defaultProfile.range,
            sourceCalendarIDs: defaultProfile.sourceCalendarIDs)
    }

    func setBrowse(_ settings: ShareBrowseSettings, for profileID: UUID) {
        browseSettings[profileID] = settings
        persist()
    }

    func resetBrowse(profile: SharedCalendarProfile) {
        browseSettings.removeValue(forKey: profile.id)
        persist()
    }

    func draft(profileID: UUID) -> SharedCalendarDraft? { drafts[profileID] }

    func saveDraft(profile: SharedCalendarProfile, baseRevision: Int? = nil) {
        saveDraft(SharedCalendarDraft(baseRevision: baseRevision ?? drafts[profile.id]?.baseRevision ?? profile.revision,
                                      profile: profile))
    }

    func saveDraft(_ draft: SharedCalendarDraft) {
        drafts[draft.id] = draft
        persist()
    }

    func discardDraft(profileID: UUID) {
        drafts.removeValue(forKey: profileID)
        if profileID == newDraftID { newDraftID = UUID() }
        persist()
    }

    private func eventKey(profileID: UUID, identityID: UUID, occurrenceKey: String?) -> String {
        "\(profileID.uuidString)|\(identityID.uuidString)|\(occurrenceKey ?? "single")"
    }

    func eventDraft(profileID: UUID, identityID: UUID, occurrenceKey: String?) -> SharedEventVisibilityDraft? {
        eventDrafts[eventKey(profileID: profileID, identityID: identityID, occurrenceKey: occurrenceKey)]
    }

    func saveEventDraft(_ draft: SharedEventVisibilityDraft) {
        eventDrafts[eventKey(profileID: draft.profileID, identityID: draft.identityID, occurrenceKey: draft.occurrenceKey)] = draft
        persist()
    }

    func discardEventDraft(profileID: UUID, identityID: UUID, occurrenceKey: String?) {
        eventDrafts.removeValue(forKey: eventKey(profileID: profileID, identityID: identityID, occurrenceKey: occurrenceKey))
        persist()
    }

    func removeProfile(profileID: UUID) {
        browseSettings.removeValue(forKey: profileID)
        drafts.removeValue(forKey: profileID)
        eventDrafts = eventDrafts.filter { $0.value.profileID != profileID }
        persist()
    }

    private func persist() {
        guard let defaults else { return }
        do {
            let data = try JSONEncoder().encode(StoredState(browseSettings: browseSettings, drafts: drafts,
                eventDrafts: eventDrafts, personalRange: personalRange, newDraftID: newDraftID))
            defaults.set(data, forKey: storageKey)
            errorMessage = nil
        } catch {
            errorMessage = NSLocalizedString("sharing.error.storage", comment: "Unable to store local sharing drafts")
        }
    }
}

struct SharedRuleReview: Sendable {
    var confirmedProfile: SharedCalendarProfile?
    var proposedProfile: SharedCalendarProfile
    var baseRevision: Int
    var addedSourceCalendarIDs: Set<String>
    var removedSourceCalendarIDs: Set<String>
    var rangeChanged: Bool
    var privacyModeChanged: Bool
    var nameChanged: Bool
    var previousEventCount: Int
    var proposedEventCount: Int
    var addedEventCount: Int
    var removedEventCount: Int
    var expandedDetailCount: Int
    var reducedDetailCount: Int
    var hasChanges: Bool
}
