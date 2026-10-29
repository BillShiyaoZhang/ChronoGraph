import SwiftUI

/// Edits local intent. Only the separate review can send its exact frozen preview.
struct CloudUploadScopeEditor: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID?
    let candidateSourceIDs: Set<String>
    let candidateRange: SharedCalendarRange?
    let onConfirmed: ((CloudSource) -> Void)?
    @State private var draft: CloudSharingDraft?
    @State private var preview: CloudSharingPreview?
    @State private var review: CloudSharingPreview?
    @State private var errorMessage: String?
    @State private var initialized = false
    @State private var isInitializing = false
    @State private var isPreviewing = false
    @State private var previewRequestID = UUID()
    @State private var userEditedName = false
    @State private var showingSources = false
    @State private var showingEvents = false
    @State private var showingRange = false
    @State private var failedReviewDraftID: UUID?
    @State private var editorScope: String?
    @State private var editorToken: String?
    @State private var needsReload = false
    @FocusState private var nameFocused: Bool

    init(source: CloudSource? = nil, sourceID: UUID? = nil, candidateSourceIDs: Set<String> = [],
         candidateRange: SharedCalendarRange? = nil, onConfirmed: ((CloudSource) -> Void)? = nil) {
        self.sourceID = sourceID ?? source?.id
        self.candidateSourceIDs = candidateSourceIDs
        self.candidateRange = candidateRange
        self.onConfirmed = onConfirmed
    }

    private var isEditing: Bool { sourceID != nil }
    private var isOriginalSession: Bool {
        editorScope != nil && editorToken != nil && cloud.homeDisplayScope == editorScope && cloud.session?.accessToken == editorToken
    }
    private var canPreview: Bool {
        guard let draft, initialized, isOriginalSession, !cloud.isBusy, !isPreviewing else { return false }
        return (try? CloudSharingPolicy.validate(draft)) != nil &&
            draft.calendarIDs.isSubset(of: Set(cloud.calendars.map(\.id)))
    }

    var body: some View {
        Form {
            if let draft { editorSections(draft) }
            if isInitializing || isPreviewing {
                Section { ProgressView(isPreviewing ? "cloud.sharing.preview.loading" : "cloud.sharing.loading") }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("cloud.sharing.error")
                    if needsReload {
                        Text("cloud.sharing.reload.help").font(.footnote).foregroundStyle(.secondary)
                        Button("cloud.sharing.reload") { reloadCurrentConfiguration() }
                            .accessibilityIdentifier("cloud.sharing.reload")
                    }
                    Button("common.retry") {
                        Task {
                            if !initialized { await initialize() }
                            else { await cloud.loadCalendars(); self.errorMessage = cloud.errorMessage }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("cloud.sharing.editor")
        .navigationTitle(isEditing ? "cloud.sharing.edit" : "cloud.sharing.create")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { dismiss() }.disabled(cloud.isBusy)
                    .accessibilityIdentifier(isEditing ? "cloud.source.level.cancel" : "cloud.upload.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("cloud.sharing.review.short") { preparePreview(openReview: true) }
                    .disabled(!canPreview).accessibilityIdentifier("cloud.sharing.review")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("common.done") { nameFocused = false }.accessibilityIdentifier("cloud.sharing.keyboard.done")
            }
        }
        .navigationDestination(isPresented: $showingSources) {
            if let draft {
                CloudSharingSourcesView(selectedIDs: Binding(get: { self.draft?.calendarIDs ?? draft.calendarIDs }, set: selectCalendars))
            }
        }
        .navigationDestination(isPresented: $showingEvents) {
            CloudSharingEventsView(preview: preview, isLoading: isPreviewing, errorMessage: errorMessage,
                onRefresh: { preparePreview() }, onApply: { updated in
                    setDraft(updated)
                    preparePreview()
                })
        }
        .sheet(isPresented: $showingRange) {
            if let draft { DateRangePickerSheet(range: draft.range) { range in editDraft { $0.range = range } } }
        }
        .sheet(item: $review, onDismiss: reviewClosed) { snapshot in
            NavigationStack {
                CloudSharingReviewView(preview: snapshot, onFailure: { failedReviewDraftID = snapshot.draft.id }) { saved in
                    review = nil
                    onConfirmed?(saved)
                    dismiss()
                }
            }
        }
        .task { await initialize() }
        .onChange(of: cloud.isBusy) { _, busy in if !busy && !initialized { Task { await initialize() } } }
        .onChange(of: cloud.homeDisplayScope) { _, _ in
            discardForSessionChange()
        }
        .onChange(of: cloud.session?.accessToken) { _, _ in discardForSessionChange() }
        .interactiveDismissDisabled(cloud.isBusy)
    }

    @ViewBuilder private func editorSections(_ value: CloudSharingDraft) -> some View {
        Section {
            TextField("cloud.sharing.name", text: Binding(get: { draft?.name ?? value.name }, set: { name in
                userEditedName = true
                editDraft { $0.name = name }
            }))
            .focused($nameFocused).submitLabel(.done).onSubmit { nameFocused = false }
            .accessibilityIdentifier("cloud.sharing.name")
            Button { nameFocused = false; showingSources = true } label: {
                HStack { Text("cloud.sharing.sources"); Spacer(); Text(value.calendarIDs.count, format: .number).foregroundStyle(.secondary); Image(systemName: "chevron.forward").font(.caption) }
            }.foregroundStyle(.primary).accessibilityIdentifier("cloud.sharing.sources")
        } footer: { Text("cloud.sharing.sources.help") }
        Section {
            SharingRangeFields(range: Binding(get: { draft?.range ?? value.range }, set: { range in editDraft { $0.range = range } }),
                               identifierPrefix: "cloud.upload.range", onCustom: { showingRange = true })
            if let message = rangeError(value.range) {
                Text(message).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("cloud.upload.range.error")
            }
        } header: { Text("sharing.range.title") }
        footer: { Text("cloud.sharing.range.help") }
        Section {
            SharingContentPicker(title: "cloud.sharing.defaultVisibility", selection: Binding(
                get: { draft?.defaultVisibility.privacyMode ?? .opaque },
                set: { mode in editDraft { $0.defaultVisibility = SharedVisibility(privacyMode: mode) } }),
                identifierPrefix: "cloud.upload.level")
        } header: { Text("cloud.sharing.defaultVisibility") }
        footer: { Text("cloud.sharing.defaultVisibility.help") }
        Section {
            Button { preparePreview(openEvents: true) } label: {
                Label("cloud.sharing.preview", systemImage: "list.bullet.rectangle")
            }
            .disabled(!canPreview).accessibilityIdentifier("cloud.sharing.preview")
            if let preview, preview.draft == value {
                LabeledContent("cloud.sharing.preview.included", value: (preview.events.count - preview.excludedCount).formatted())
                LabeledContent("cloud.sharing.preview.excluded", value: preview.excludedCount.formatted())
            } else {
                Text("cloud.sharing.preview.required").font(.footnote).foregroundStyle(.secondary)
            }
        } footer: { Text("cloud.sharing.preview.localOnly") }
    }

    private func setDraft(_ value: CloudSharingDraft) {
        guard isOriginalSession else { discardForSessionChange(); return }
        guard draft != value else { return }
        previewRequestID = UUID()
        isPreviewing = false
        preview = nil
        review = nil
        errorMessage = nil
        draft = value
    }
    private func editDraft(_ change: (inout CloudSharingDraft) -> Void) {
        guard var value = draft else { return }
        change(&value)
        setDraft(value)
    }
    private func selectCalendars(_ ids: Set<String>) {
        editDraft { value in
            value.calendarIDs = ids
            if !userEditedName { value.name = suggestedName(ids) }
        }
    }
    private func suggestedName(_ ids: Set<String>) -> String {
        if ids.count == 1, let calendar = cloud.calendars.first(where: { ids.contains($0.id) }) { return calendar.title }
        return ids.isEmpty ? "" : NSLocalizedString("cloud.sharing.defaultName", comment: "Default multi-calendar configuration name")
    }
    private func rangeError(_ range: SharedCalendarRange) -> String? {
        do { _ = try CloudUploadScopePolicy.interval(for: range); return nil }
        catch { return CloudCopy.error(error) }
    }
    private func initialize() async {
        guard !initialized, !isInitializing, !cloud.isBusy else { return }
        isInitializing = true
        let scope = cloud.homeDisplayScope, token = cloud.session?.accessToken
        editorScope = scope
        editorToken = token
        defer { isInitializing = false }
        await cloud.loadCalendars()
        guard scope != nil, token != nil, cloud.homeDisplayScope == scope, cloud.session?.accessToken == token else {
            discardForSessionChange()
            return
        }
        do {
            var value = try cloud.makeSharingDraft(sourceID: sourceID)
            if sourceID == nil {
                value.calendarIDs = candidateSourceIDs.intersection(Set(cloud.calendars.map(\.id)))
                if let candidateRange { value.range = candidateRange }
                if value.name.isEmpty { value.name = suggestedName(value.calendarIDs) }
            }
            userEditedName = sourceID != nil || (!value.name.isEmpty && value.name != suggestedName(value.calendarIDs))
            draft = value
            initialized = true
            errorMessage = cloud.errorMessage
        } catch { errorMessage = CloudCopy.error(error) }
    }
    private func preparePreview(openEvents: Bool = false, openReview: Bool = false) {
        nameFocused = false
        guard isOriginalSession else { discardForSessionChange(); return }
        guard canPreview, let value = draft else { return }
        if let preview, preview.draft == value {
            if openEvents { showingEvents = true }
            if openReview { review = preview }
            if openEvents || openReview { return }
        }
        let request = UUID(), scope = editorScope, token = editorToken
        previewRequestID = request
        isPreviewing = true
        errorMessage = nil
        preview = nil
        if openEvents { showingEvents = true }
        Task {
            guard previewRequestID == request, isOriginalSession,
                  cloud.homeDisplayScope == scope, cloud.session?.accessToken == token else { return }
            do {
                let snapshot = try await cloud.previewSharing(draft: value)
                guard previewRequestID == request, cloud.homeDisplayScope == scope, cloud.session?.accessToken == token else { return }
                draft = snapshot.draft
                preview = snapshot
                isPreviewing = false
                if openReview { review = snapshot }
            } catch {
                guard previewRequestID == request, cloud.homeDisplayScope == scope, cloud.session?.accessToken == token else { return }
                preview = nil
                isPreviewing = false
                errorMessage = CloudCopy.error(error)
                if case CloudSharingError.reviewExpired = error {
                    needsReload = cloud.bindings.contains { $0.sourceId == value.id }
                }
            }
        }
    }
    private func reviewClosed() {
        // Every new confirmation gets a fresh read and review registration.
        preview = nil
        if let id = failedReviewDraftID,
           cloud.pendingSharingDrafts.contains(where: { $0.id == id }),
           let recovered = try? cloud.makeSharingDraft(sourceID: id) {
            draft = recovered
            userEditedName = true
            needsReload = false
        } else if let id = failedReviewDraftID, cloud.bindings.contains(where: { $0.sourceId == id }) {
            needsReload = true
            errorMessage = CloudCopy.error(CloudSharingError.reviewExpired)
        }
        failedReviewDraftID = nil
    }
    private func discardForSessionChange() {
        previewRequestID = UUID()
        preview = nil
        review = nil
        isPreviewing = false
        nameFocused = false
        dismiss()
    }
    private func reloadCurrentConfiguration() {
        guard isOriginalSession, let id = sourceID ?? draft?.id else { discardForSessionChange(); return }
        do {
            let latest = try cloud.makeSharingDraft(sourceID: id)
            setDraft(latest)
            userEditedName = true
            needsReload = false
            errorMessage = nil
        } catch { errorMessage = CloudCopy.error(error) }
    }
}

private struct CloudSharingSourcesView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedIDs: Set<String>
    private var missingIDs: [String] { selectedIDs.subtracting(Set(cloud.calendars.map(\.id))).sorted() }
    var body: some View {
        List {
            Section {
                ForEach(cloud.calendars) { calendar in
                    Button {
                        if !selectedIDs.insert(calendar.id).inserted { selectedIDs.remove(calendar.id) }
                    } label: { SharingSourceRow(title: calendar.title, account: calendar.account, isSelected: selectedIDs.contains(calendar.id)) }
                    .accessibilityIdentifier("cloud.upload.calendar.\(calendar.id)")
                    .accessibilityAddTraits(selectedIDs.contains(calendar.id) ? .isSelected : [])
                }
            } footer: { Text("cloud.sharing.sources.help") }
            if !missingIDs.isEmpty {
                Section("cloud.sharing.sources.unavailable") {
                    ForEach(missingIDs, id: \.self) { id in
                        Button(role: .destructive) { selectedIDs.remove(id) } label: { Label("cloud.sharing.sources.removeUnavailable", systemImage: "calendar.badge.exclamationmark") }
                            .accessibilityIdentifier("cloud.upload.calendar.\(id)")
                    }
                }
            }
            if cloud.calendars.isEmpty {
                Section { Text("cloud.sharing.sources.empty").foregroundStyle(.secondary) }
            }
        }
        .accessibilityIdentifier("cloud.sharing.sources.list")
        .navigationTitle("cloud.sharing.sources")
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            Button("common.done") { dismiss() }.accessibilityIdentifier("cloud.sharing.sources.done")
        } }
    }
}

private struct CloudSharingEventsView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let preview: CloudSharingPreview?
    let isLoading: Bool
    let errorMessage: String?
    let onRefresh: () -> Void
    let onApply: (CloudSharingDraft) -> Void
    @State private var selectedEvent: SharedEventPreview?
    @State private var selectedDraft: CloudSharingDraft?
    private var sourceLabels: [String: String] { Dictionary(uniqueKeysWithValues: cloud.calendars.map { ($0.id, $0.title + " · " + $0.account) }) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("cloud.sharing.preview.localOnly").font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                if isLoading { ProgressView("cloud.sharing.preview.loading").frame(maxWidth: .infinity).padding() }
                else if let errorMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("cloud.sharing.error")
                        Button("common.retry", action: onRefresh)
                    }.padding()
                } else if let preview {
                    InAppEventListView(sharedEvents: preview.events, dateInterval: preview.interval,
                        timeZone: TimeZone(identifier: preview.draft.range.timeZoneIdentifier) ?? .current,
                        collapseEmptyDays: true, displayMode: .partial, showsUnshared: true,
                        identifierPrefix: "cloud.sharing.event", sourceLabels: sourceLabels, onSelect: {
                            selectedDraft = preview.draft
                            selectedEvent = $0
                        })
                }
            }.padding(.top, 8)
        }
        .accessibilityIdentifier("cloud.sharing.events.list")
        .navigationTitle("cloud.sharing.preview")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .disabled(isLoading || cloud.isBusy).accessibilityLabel(Text("common.retry"))
                    .accessibilityIdentifier("cloud.sharing.events.refresh")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.done") { dismiss() }.accessibilityIdentifier("cloud.sharing.events.done")
            }
        }
        .sheet(item: $selectedEvent) { event in
            if let selectedDraft {
                NavigationStack {
                    CloudSharingEventRuleEditor(draft: selectedDraft, event: event, onApply: onApply)
                }
            }
        }
    }
}

private struct CloudSharingEventRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    let draft: CloudSharingDraft
    let event: SharedEventPreview
    let onApply: (CloudSharingDraft) -> Void
    @State private var entireSeries = false
    @State private var selection: String
    init(draft: CloudSharingDraft, event: SharedEventPreview, onApply: @escaping (CloudSharingDraft) -> Void) {
        self.draft = draft; self.event = event; self.onApply = onApply
        _selection = State(initialValue: event.override?.rawValue ?? "inherit")
    }
    private var editedDraft: CloudSharingDraft {
        var value = draft
        value.ruleState.setVisibility(SharedVisibility(rawValue: selection), profileID: draft.id,
            sourceKey: SourceInstanceKey(sourceIdentityID: event.identityID, occurrenceKey: event.occurrenceKey),
            scope: entireSeries ? .series : .occurrence)
        return value
    }
    private var proposed: PublishedEvent? {
        guard let original = event.source else { return nil }
        let key = SourceInstanceKey(sourceIdentityID: event.identityID, occurrenceKey: event.occurrenceKey)
        return PublishedEvent(source: original, visibility: CloudSharingPolicy.visibility(draft: editedDraft, key: key))
    }
    private var hasChanges: Bool {
        selection != ((entireSeries ? event.seriesOverride : event.override)?.rawValue ?? "inherit")
    }
    var body: some View {
        Form {
            SharedEventOriginalSection(event: event, identifierPrefix: "cloud.sharing.event.original")
            SharedEventVisibilityFields(isRecurring: event.isRecurring, occurrenceOverride: event.override,
                seriesOverride: event.seriesOverride, defaultVisibility: draft.defaultVisibility,
                entireSeries: $entireSeries, selection: $selection, identifierPrefix: "cloud.sharing.event.rule")
            Section("sharing.preview.proposed") {
                SharedPublishedEventPreview(published: proposed)
                if entireSeries && event.override != nil {
                    Text("sharing.preview.occurrenceWins").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section { Text("cloud.sharing.event.localOnly").font(.footnote).foregroundStyle(.secondary) }
        }
        .environment(\.timeZone, TimeZone(identifier: draft.range.timeZoneIdentifier) ?? .current)
        .navigationTitle("sharing.override.title")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { dismiss() }.accessibilityIdentifier("cloud.sharing.event.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("cloud.sharing.event.apply") { onApply(editedDraft); dismiss() }
                    .disabled(!hasChanges || event.source == nil).accessibilityIdentifier("cloud.sharing.event.apply")
            }
        }
    }
}

private struct CloudSharingReviewView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let preview: CloudSharingPreview
    let onFailure: () -> Void
    let onConfirmed: (CloudSource) -> Void
    @State private var consent = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var needsNewReview = false
    private var sourceLabels: [String: String] { Dictionary(uniqueKeysWithValues: cloud.calendars.map { ($0.id, $0.title + " · " + $0.account) }) }
    var body: some View {
        List {
            Section("cloud.sharing.review.scope") {
                LabeledContent("sharing.name", value: preview.draft.name)
                SharingScopeSummary(channel: .cloud, range: preview.draft.range, sourceCount: preview.draft.calendarIDs.count,
                    content: preview.draft.defaultVisibility.privacyMode ?? .opaque, destination: cloud.endpoint,
                    contentTitle: "cloud.sharing.defaultVisibility")
                LabeledContent("cloud.sharing.review.maximumDetails", value: preview.draft.uploadLevel.label)
                ForEach(cloud.calendars.filter { preview.draft.calendarIDs.contains($0.id) }) { calendar in
                    SharingSourceRow(title: calendar.title, account: calendar.account, isSelected: true)
                }
            }
            Section("cloud.sharing.review.events") {
                LabeledContent("cloud.sharing.preview.included", value: (preview.events.count - preview.excludedCount).formatted())
                LabeledContent("cloud.sharing.preview.excluded", value: preview.excludedCount.formatted())
                LabeledContent("cloud.sharing.review.occurrenceRules", value: (activeOverrides.count - seriesRuleCount).formatted())
                LabeledContent("cloud.sharing.review.seriesRules", value: seriesRuleCount.formatted())
                NavigationLink("cloud.sharing.review.projection") {
                    CloudSharingProjectionView(preview: preview)
                }.accessibilityIdentifier("cloud.sharing.review.projection")
            }
            Section("sharing.transfer.title") {
                Text(cloud.isUploadPaused(preview.draft.id)
                     ? LocalizedStringKey("cloud.sharing.review.transfer.paused")
                     : LocalizedStringKey("cloud.sharing.review.transfer")).font(.footnote)
                Text("cloud.sharing.review.rules").font(.footnote)
                Text("cloud.sharing.review.separate").font(.footnote).accessibilityIdentifier("cloud.upload.independentRules")
                if preview.draft.baseGeneration != nil {
                    DisclosureGroup("cloud.sharing.review.service.title") {
                        Text("cloud.sharing.review.service.details").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Toggle("cloud.sharing.review.consent", isOn: $consent).accessibilityIdentifier("cloud.upload.consent")
                Button("cloud.sharing.review.confirm") { save() }
                    .disabled(!consent || isSaving || cloud.isBusy || needsNewReview)
                    .accessibilityIdentifier(preview.draft.baseGeneration == nil ? "cloud.upload.confirm" : "cloud.source.level.confirm")
            }
            if isSaving { Section { ProgressView() } }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("cloud.sharing.error")
                    Text("cloud.sharing.review.retry").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("cloud.sharing.review.list")
        .navigationTitle("sharing.review.title")
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button("sharing.review.back") { dismiss() }.disabled(isSaving || cloud.isBusy)
                .accessibilityIdentifier("cloud.sharing.review.back")
        } }
        .interactiveDismissDisabled(isSaving || cloud.isBusy)
    }
    private var activeOverrides: [SharedVisibilityOverride] {
        let identities = Set(preview.draft.ruleState.identities.filter { preview.draft.calendarIDs.contains($0.calendarID) }.map(\.id))
        return preview.draft.ruleState.overrides.filter { $0.profileID == preview.draft.id && identities.contains($0.sourceIdentityID) }
    }
    private var seriesRuleCount: Int {
        let series = Set(preview.draft.ruleState.identities.filter(\.isRecurring).map(\.id))
        return activeOverrides.filter { $0.occurrenceKey == nil && series.contains($0.sourceIdentityID) }.count
    }
    private func save() {
        guard consent, !isSaving, !cloud.isBusy, !needsNewReview else { return }
        isSaving = true
        errorMessage = nil
        Task {
            if let saved = await cloud.saveSharing(preview: preview) { onConfirmed(saved) }
            else {
                errorMessage = cloud.errorMessage ?? CloudCopy.error(CloudSharingError.reviewExpired)
                consent = false
                needsNewReview = true
                onFailure()
            }
            isSaving = false
        }
    }
}

private struct CloudSharingProjectionView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    let preview: CloudSharingPreview
    @State private var selectedEvent: SharedEventPreview?
    private var sourceLabels: [String: String] { Dictionary(uniqueKeysWithValues: cloud.calendars.map { ($0.id, $0.title + " · " + $0.account) }) }
    var body: some View {
        ScrollView {
            InAppEventListView(sharedEvents: preview.events, dateInterval: preview.interval,
                timeZone: TimeZone(identifier: preview.draft.range.timeZoneIdentifier) ?? .current,
                collapseEmptyDays: true, identifierPrefix: "cloud.sharing.review.event", sourceLabels: sourceLabels,
                onSelect: { selectedEvent = $0 })
        }
        .navigationTitle("cloud.sharing.review.projection")
        .sheet(item: $selectedEvent) { event in
            NavigationStack { CloudSharingPublishedDetail(event: event) }
        }
    }
}

private struct CloudSharingPublishedDetail: View {
    @Environment(\.dismiss) private var dismiss
    let event: SharedEventPreview
    var body: some View {
        Form { Section("cloud.sharing.review.projection") { SharedPublishedEventPreview(published: event.published) } }
            .navigationTitle("cloud.sharing.review.projection")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } } }
    }
}
