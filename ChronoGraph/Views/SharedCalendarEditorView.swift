import SwiftUI

struct SharedCalendarEditorView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    @EnvironmentObject private var workspace: SharingWorkspace
    @Environment(\.dismiss) private var dismiss
    private let existingProfile: SharedCalendarProfile?
    private let initialBrowse: ShareBrowseSettings?
    private let reviewsBrowseOnOpen: Bool
    private let opensRangeEditor: Bool
    private let onCreated: ((SharedCalendarProfile) -> Void)?
    @State private var proposed: SharedCalendarProfile
    @State private var original: SharedCalendarProfile
    @State private var baseRevision: Int
    @State private var hasLoaded = false
    @State private var confirmsICloud = false
    @State private var showingRange = false
    @State private var showingReview = false
    @State private var showingClose = false
    @State private var showingCreatedGuide = false
    @State private var showingBrowseDraftChoice = false
    @State private var publicationCompleted: Bool?

    init(profile: SharedCalendarProfile?, defaultSourceIDs: Set<String>, defaultPrivacyMode: PrivacyMode,
         initialBrowse: ShareBrowseSettings? = nil, reviewsBrowseOnOpen: Bool = false,
         opensRangeEditor: Bool = false,
         onCreated: ((SharedCalendarProfile) -> Void)? = nil) {
        existingProfile = profile
        self.initialBrowse = initialBrowse
        self.reviewsBrowseOnOpen = reviewsBrowseOnOpen
        self.opensRangeEditor = opensRangeEditor
        self.onCreated = onCreated
        let value = profile ?? SharedCalendarProfile(name: "", sourceCalendarIDs: defaultSourceIDs,
                                                      targetSourceID: "", privacyMode: defaultPrivacyMode)
        _proposed = State(initialValue: value)
        _original = State(initialValue: value)
        _baseRevision = State(initialValue: value.revision)
    }

    private var availableCalendars: [SharedCalendarOption] { manager.calendars.filter { !$0.isManaged } }
    private var selectedAccount: SharedCalendarAccount? { manager.accounts.first { $0.id == proposed.targetSourceID } }
    private var hasChanges: Bool {
        var baseline = original
        baseline.id = proposed.id
        return proposed != baseline
    }
    private var isStale: Bool { existingProfile != nil && manager.profiles.first { $0.id == proposed.id }?.revision != baseRevision }
    private var canReview: Bool {
        !manager.isBusy && !isStale && !proposed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !proposed.targetSourceID.isEmpty && (existingProfile != nil || (confirmsICloud && selectedAccount != nil)) &&
        (try? proposed.range.dateInterval()) != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("sharing.name", text: $proposed.name)
                    .textInputAutocapitalization(.words).accessibilityIdentifier("sharing.name")
                if existingProfile == nil {
                    Picker("sharing.account", selection: $proposed.targetSourceID) {
                        Text("sharing.account.choose").tag("")
                        ForEach(manager.accounts) { account in Text(account.title).tag(account.id) }
                    }
                    .accessibilityIdentifier("sharing.account")
                    .onChange(of: proposed.targetSourceID) { _, _ in confirmsICloud = false }
                    if let account = selectedAccount {
                        if !account.calendarTitles.isEmpty { Text(account.calendarTitles.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        Toggle("sharing.account.confirm", isOn: $confirmsICloud).accessibilityIdentifier("sharing.account.confirm")
                    }
                    if manager.accounts.isEmpty { Label("sharing.account.empty", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                } else {
                    LabeledContent("sharing.account", value: selectedAccount?.title ?? NSLocalizedString("sharing.account.unavailable", comment: ""))
                }
            } footer: { Text(existingProfile == nil ? LocalizedStringKey("sharing.account.help") : LocalizedStringKey("sharing.account.fixed")) }

            Section("sharing.transfer.title") {
                Text("sharing.transfer.setup")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("sharing.transfer.setup")
            }

            Section {
                Picker("sharing.defaultVisibility", selection: $proposed.privacyMode) {
                    ForEach(PrivacyMode.allCases, id: \.rawValue) { mode in
                        Text(mode.localizedKey).tag(mode).accessibilityIdentifier("sharing.draft.privacy.\(mode.rawValue)")
                    }
                }
                .accessibilityIdentifier("sharing.draft.privacy")
                Text(visibilityDescriptionKey).font(.caption).foregroundStyle(.secondary)
            } footer: { Text("sharing.draft.localOnly") }

            Section("sharing.range.title") {
                SharedRangeSummary(range: proposed.range)
                DateRangeMenu(selection: proposed.range, onSelect: { proposed.range = $0 }, onCustom: { showingRange = true }, identifierPrefix: "sharing.draft.range", showsTitle: true)
                    .accessibilityLabel(Text("sharing.range.title"))
                Button("dateRange.custom") { showingRange = true }.accessibilityIdentifier("sharing.draft.range.customize")
                LabeledContent("sharing.range.timeZone", value: proposed.range.timeZoneIdentifier)
            }

            Section {
                ForEach(availableCalendars) { calendar in
                    Button { toggle(calendar.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(calendar.title).foregroundStyle(.primary)
                                Text(calendar.sourceTitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if proposed.sourceCalendarIDs.contains(calendar.id) { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("sharing.draft.source.\(calendar.id)")
                    .accessibilityAddTraits(proposed.sourceCalendarIDs.contains(calendar.id) ? .isSelected : [])
                }
                if availableCalendars.isEmpty { Text("calendars.empty").foregroundStyle(.secondary) }
                let unavailable = proposed.sourceCalendarIDs.subtracting(availableCalendars.map(\.id))
                if !unavailable.isEmpty {
                    Label("sharing.sources.unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("sharing.sources.removeUnavailable") { proposed.sourceCalendarIDs.subtract(unavailable) }
                }
                HStack {
                    Button("calendars.selectAll") { proposed.sourceCalendarIDs = Set(availableCalendars.map(\.id)) }
                    Spacer()
                    Button("calendars.clear") { proposed.sourceCalendarIDs.removeAll() }
                }
            } header: { Text("sharing.sources") }
            footer: { Text("sharing.sources.help") }

            if let initialBrowse {
                Section {
                    Button("sharing.draft.copyBrowse") {
                        importBrowseScope(initialBrowse)
                    }
                    .accessibilityIdentifier("sharing.draft.copyBrowse")
                } footer: { Text("sharing.draft.copyBrowse.help") }
            }
            if isStale {
                Section {
                    Label("sharing.draft.stale", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("sharing.draft.restart") {
                        guard let latest = manager.profiles.first(where: { $0.id == proposed.id }) else { return }
                        workspace.discardDraft(profileID: proposed.id)
                        proposed = latest
                        original = latest
                        baseRevision = latest.revision
                    }
                    .accessibilityIdentifier("sharing.draft.restart")
                }
            }
            Section { Text("sharing.draft.review.help").font(.footnote).foregroundStyle(.secondary) }
        }
        .disabled(manager.isBusy)
        .navigationTitle(existingProfile == nil ? Text("sharing.create") : Text("sharing.edit"))
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { close() }.disabled(manager.isBusy).accessibilityIdentifier("sharing.draft.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("sharing.review.action") { persistDraft(); showingReview = true }
                    .disabled(!canReview).accessibilityIdentifier("sharing.save")
            }
        }
        .interactiveDismissDisabled(hasChanges || manager.isBusy)
        .task {
            guard !hasLoaded else { return }
            if existingProfile == nil { proposed.id = workspace.newDraftID }
            let saved = workspace.draft(profileID: proposed.id)
            if let saved { proposed = saved.profile; baseRevision = saved.baseRevision }
            hasLoaded = true
            if reviewsBrowseOnOpen, existingProfile != nil, initialBrowse != nil, !isStale {
                if saved != nil { showingBrowseDraftChoice = true }
                else { reviewBrowseScope() }
            } else if opensRangeEditor { showingRange = true }
            manager.refresh()
        }
        .onChange(of: proposed) { _, _ in if hasLoaded { persistDraft() } }
        .sheet(isPresented: $showingRange) { DateRangePickerSheet(range: proposed.range) { proposed.range = $0 } }
        .sheet(isPresented: $showingReview, onDismiss: completeReview) {
            NavigationStack {
                SharedCalendarReviewView(draft: SharedCalendarDraft(baseRevision: baseRevision, profile: proposed)) { succeeded in
                    publicationCompleted = succeeded
                    showingReview = false
                }
            }
        }
        .sheet(isPresented: $showingCreatedGuide, onDismiss: { dismiss() }) {
            NavigationStack { SharedCalendarGuideView(calendarName: EventKitCalendarStore.namePrefix + proposed.name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        .confirmationDialog("sharing.draft.close.title", isPresented: $showingClose, titleVisibility: .visible) {
            Button("sharing.draft.keep") { persistDraft(); dismiss() }
            Button("sharing.draft.discard", role: .destructive) { workspace.discardDraft(profileID: proposed.id); dismiss() }
            Button("sharing.draft.continue", role: .cancel) { }
        } message: { Text("sharing.draft.close.message") }
        .confirmationDialog("sharing.draft.browseConflict.title", isPresented: $showingBrowseDraftChoice, titleVisibility: .visible) {
            Button("sharing.draft.browseConflict.merge") { reviewBrowseScope() }
                .accessibilityIdentifier("sharing.draft.browse.merge")
            Button("sharing.draft.browseConflict.edit") { }
                .accessibilityIdentifier("sharing.draft.browse.edit")
            Button("common.cancel", role: .cancel) { dismiss() }
                .accessibilityIdentifier("sharing.draft.browse.cancel")
        } message: { Text("sharing.draft.browseConflict.message") }
    }

    private func toggle(_ id: String) {
        if !proposed.sourceCalendarIDs.insert(id).inserted { proposed.sourceCalendarIDs.remove(id) }
    }
    private func importBrowseScope(_ browse: ShareBrowseSettings) {
        proposed.range = browse.range
        proposed.sourceCalendarIDs = browse.sourceCalendarIDs.subtracting(manager.calendars.filter(\.isManaged).map(\.id))
    }
    private func reviewBrowseScope() {
        guard let initialBrowse else { return }
        importBrowseScope(initialBrowse)
        persistDraft()
        showingReview = true
    }
    private var visibilityDescriptionKey: LocalizedStringKey {
        switch proposed.privacyMode {
        case .opaque: return "privacy.opaque.desc"
        case .partial: return "privacy.partial.desc"
        case .full: return "privacy.full.desc"
        }
    }
    private func persistDraft() { workspace.saveDraft(profile: proposed, baseRevision: baseRevision) }
    private func completeReview() {
        guard let succeeded = publicationCompleted else { return }
        publicationCompleted = nil
        if succeeded && existingProfile == nil {
            if let onCreated, let created = manager.profiles.first(where: { $0.id == proposed.id }) { onCreated(created); dismiss() }
            else { showingCreatedGuide = true }
        } else { dismiss() }
    }
    private func close() {
        if hasChanges { showingClose = true }
        else { workspace.discardDraft(profileID: proposed.id); dismiss() }
    }
}

struct SharedCalendarReviewView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    @EnvironmentObject private var workspace: SharingWorkspace
    @Environment(\.dismiss) private var dismiss
    let draft: SharedCalendarDraft
    let onCompleted: (Bool) -> Void
    @State private var review: SharedRuleReview?
    @State private var isLoading = true
    @State private var isPublishing = false
    @State private var operationError: String?
    @State private var savedBeforeFailure = false
    @State private var confirmsTransfer = false

    private var isBusy: Bool { isLoading || isPublishing || manager.isBusy }
    var body: some View {
        List {
            SharedCalendarReviewSummary(profile: draft.profile)
            if isLoading { ProgressView("sharing.review.loading") }
            else if let review {
                Section("sharing.review.changes") {
                    if review.nameChanged { Label("sharing.review.nameChanged", systemImage: "pencil") }
                    if review.rangeChanged { Label("sharing.review.rangeChanged", systemImage: "calendar") }
                    if review.privacyModeChanged { Label("sharing.review.privacyChanged", systemImage: "eye") }
                    if !review.addedSourceCalendarIDs.isEmpty { LabeledContent("sharing.review.sourcesAdded", value: "\(review.addedSourceCalendarIDs.count)") }
                    if !review.removedSourceCalendarIDs.isEmpty { LabeledContent("sharing.review.sourcesRemoved", value: "\(review.removedSourceCalendarIDs.count)") }
                    if !review.hasChanges { Text("sharing.review.noChanges").foregroundStyle(.secondary) }
                }
                Section("sharing.review.events") {
                    LabeledContent("sharing.review.currentCount", value: "\(review.previousEventCount)")
                    LabeledContent("sharing.review.proposedCount", value: "\(review.proposedEventCount)")
                    LabeledContent("sharing.review.addedCount", value: "\(review.addedEventCount)")
                    LabeledContent("sharing.review.removedCount", value: "\(review.removedEventCount)")
                    LabeledContent("sharing.review.expandedCount", value: "\(review.expandedDetailCount)").foregroundStyle(review.expandedDetailCount > 0 ? .orange : .primary)
                    LabeledContent("sharing.review.reducedCount", value: "\(review.reducedDetailCount)")
                }
                if draft.profile.isPaused { Section { Label("sharing.review.paused", systemImage: "pause.circle").foregroundStyle(.secondary) } }
                SharedCalendarTransferConsent(confirmsTransfer: $confirmsTransfer)
                    .disabled(isBusy)
                Section {
                    Button { Task { await publish(review) } } label: {
                        Text(review.confirmedProfile == nil ? LocalizedStringKey("sharing.review.confirmCreate") : LocalizedStringKey("sharing.review.confirmUpdate"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).disabled(isBusy || !confirmsTransfer).accessibilityIdentifier("sharing.review.confirm")
                } footer: { Text("sharing.review.estimate.help") }
            } else {
                Section { Button("common.retry") { Task { await loadReview() } }.disabled(isBusy) }
            }
        }
        .navigationTitle("sharing.review.title")
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button("sharing.review.back") { dismiss() }.disabled(isPublishing)
                .accessibilityIdentifier("sharing.review.back")
        } }
        .interactiveDismissDisabled(isPublishing)
        .task { await loadReview() }
        .alert(Text(savedBeforeFailure ? LocalizedStringKey("sharing.save.savedTitle") : LocalizedStringKey("sharing.error.title")), isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("common.done") { if savedBeforeFailure { onCompleted(false) } }
        } message: {
            if savedBeforeFailure { Text("sharing.save.savedNotPublished") + Text("\n\n") + Text(operationError ?? "") }
            else { Text(operationError ?? "") }
        }
    }

    private func loadReview() async {
        confirmsTransfer = false
        isLoading = true
        defer { isLoading = false }
        do { review = try await manager.review(draft) }
        catch { review = nil; operationError = error.localizedDescription }
    }
    private func publish(_ review: SharedRuleReview) async {
        guard !isBusy, confirmsTransfer else { return }
        isPublishing = true
        defer { isPublishing = false }
        let previousProfile = manager.profiles.first { $0.id == draft.profile.id }
        do {
            if review.confirmedProfile == nil { try await manager.create(review.proposedProfile) }
            else { try await manager.update(review.proposedProfile) }
            workspace.discardDraft(profileID: draft.profile.id)
            onCompleted(true)
        } catch {
            if let latest = manager.profiles.first(where: { $0.id == draft.profile.id }) {
                savedBeforeFailure = previousProfile == nil || latest.revision != previousProfile?.revision
            }
            if savedBeforeFailure { workspace.discardDraft(profileID: draft.profile.id) }
            operationError = error.localizedDescription
        }
    }
}

struct SharedCalendarTransferConsent: View {
    @Binding var confirmsTransfer: Bool

    var body: some View {
        Section("sharing.transfer.title") {
            Text("sharing.transfer.destination")
                .accessibilityIdentifier("sharing.transfer.destination")
            Text("sharing.transfer.fields")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("sharing.transfer.fields")
            Text("sharing.transfer.ongoing")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("sharing.transfer.ongoing")
            Toggle("sharing.transfer.confirm", isOn: $confirmsTransfer)
                .accessibilityIdentifier("sharing.transfer.confirm")
        }
    }
}

struct SharedCalendarReviewSummary: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    let profile: SharedCalendarProfile
    var body: some View {
        Section("sharing.review.target") {
            LabeledContent("sharing.review.destination", value: EventKitCalendarStore.namePrefix + profile.name)
            LabeledContent("sharing.account", value: manager.accounts.first { $0.id == profile.targetSourceID }?.title ?? NSLocalizedString("sharing.account.unavailable", comment: ""))
            SharedRangeSummary(range: profile.range)
            LabeledContent("sharing.defaultVisibility") { Text(profile.privacyMode.localizedKey) }
            VStack(alignment: .leading, spacing: 5) {
                Text("sharing.sources").foregroundStyle(.secondary)
                if profile.sourceCalendarIDs.isEmpty { Text("home.sources.empty") }
                ForEach(profile.sourceCalendarIDs.sorted(), id: \.self) { id in
                    Text(manager.calendars.first { $0.id == id }?.title ?? NSLocalizedString("sharing.sources.unavailable", comment: ""))
                }
            }
        }
    }
}
