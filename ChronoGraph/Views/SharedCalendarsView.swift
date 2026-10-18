import SwiftUI

struct SharedCalendarsView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    let defaultSourceIDs: Set<String>
    let defaultPrivacyMode: PrivacyMode
    @State private var showingCreate = false
    @State private var deletionCandidate: SharedCalendarProfile?
    @State private var operationError: String?

    var body: some View {
        List {
            if manager.isBusy { ProgressView("sharing.status.updating") }
            if manager.profiles.isEmpty {
                ContentUnavailableView("sharing.empty.title", systemImage: "calendar.badge.plus", description: Text("sharing.empty.description"))
            }
            ForEach(manager.profiles) { profile in
                NavigationLink {
                    SharedCalendarDetailView(profileID: profile.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile.name).font(.headline)
                        SharedCalendarStatusView(profile: profile)
                    }
                    .padding(.vertical, 3)
                }
                .swipeActions {
                    Button(role: .destructive) { deletionCandidate = profile } label: {
                        Label("common.delete", systemImage: "trash")
                    }
                }
            }
            Section {
                Text("sharing.background.help").font(.footnote).foregroundStyle(.secondary)
            }
            if let error = manager.errorMessage {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .navigationTitle("sharing.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingCreate = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(Text("sharing.create"))
                    .accessibilityIdentifier("sharing.create")
                    .disabled(manager.isBusy)
            }
        }
        .sheet(isPresented: $showingCreate) {
            NavigationStack {
                SharedCalendarEditorView(profile: nil, defaultSourceIDs: defaultSourceIDs, defaultPrivacyMode: defaultPrivacyMode)
            }
        }
        .task { manager.refresh() }
        .refreshable { manager.refresh() }
        .alert("sharing.delete.title", isPresented: Binding(get: { deletionCandidate != nil }, set: { if !$0 { deletionCandidate = nil } })) {
            Button("common.delete", role: .destructive) {
                guard let profile = deletionCandidate else { return }
                deletionCandidate = nil
                Task {
                    do { try await manager.delete(profileID: profile.id) }
                    catch { operationError = error.localizedDescription }
                }
            }
            Button("common.cancel", role: .cancel) { deletionCandidate = nil }
        } message: { Text("sharing.delete.message") }
        .sharingErrorAlert($operationError)
    }
}

struct SharedCalendarStatusView: View {
    let profile: SharedCalendarProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if profile.pendingDeletion {
                Label("sharing.status.pendingDeletion", systemImage: "trash").foregroundStyle(.orange)
            } else if profile.isPaused {
                Label("sharing.status.paused", systemImage: "pause.circle").foregroundStyle(.secondary)
            } else if profile.lastUpdated == nil {
                Label("sharing.status.pending", systemImage: "clock").foregroundStyle(.secondary)
            }
            if let error = profile.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let date = profile.lastUpdated {
                HStack(spacing: 4) {
                    Text("sharing.lastLocalUpdate")
                    Text(date, format: .dateTime.month().day().hour().minute())
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

private struct SharedCalendarDetailView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID
    @State private var events: [SharedEventPreview] = []
    @State private var isLoading = false
    @State private var operationError: String?
    @State private var showingEditor = false
    @State private var showingGuide = false
    @State private var showingDelete = false
    @State private var showingRecreate = false
    @State private var selectedEvent: SharedEventPreview?

    private var profile: SharedCalendarProfile? { manager.profiles.first { $0.id == profileID } }

    var body: some View {
        Group {
            if let profile {
                List {
                    Section {
                        SharedCalendarStatusView(profile: profile)
                        Button {
                            Task {
                                do { try await manager.sync(profileID: profileID); await reload() }
                                catch { operationError = error.localizedDescription }
                            }
                        } label: { Label("sharing.updateNow", systemImage: "arrow.clockwise") }
                        .disabled(manager.isBusy || profile.pendingDeletion || profile.isPaused)
                        Button {
                            Task {
                                do { try await manager.setPaused(profileID: profileID, paused: !profile.isPaused) }
                                catch { operationError = error.localizedDescription }
                            }
                        } label: {
                            Label {
                                Text(profile.isPaused ? LocalizedStringKey("sharing.resume") : LocalizedStringKey("sharing.pause"))
                            } icon: { Image(systemName: profile.isPaused ? "play.circle" : "pause.circle") }
                        }
                        .disabled(manager.isBusy || profile.pendingDeletion)
                        Button { showingGuide = true } label: { Label("sharing.guide.title", systemImage: "person.2") }
                        if profile.targetCalendarID == nil || !manager.calendars.contains(where: { $0.id == profile.targetCalendarID }) {
                            Button { showingRecreate = true } label: {
                                Label("sharing.recreate.action", systemImage: "calendar.badge.plus")
                            }
                            .disabled(manager.isBusy || profile.pendingDeletion)
                        }
                    } footer: { Text("sharing.pause.help") }

                    Section {
                        HStack { Text("sharing.defaultVisibility"); Spacer(); Text(profile.privacyMode.localizedKey).foregroundStyle(.secondary) }
                        SharedRangeSummary(range: profile.range)
                        Button("sharing.edit") { showingEditor = true }.disabled(manager.isBusy || profile.pendingDeletion)
                    }

                    Section {
                        if isLoading { ProgressView().frame(maxWidth: .infinity) }
                        else if events.isEmpty { Text("sharing.events.empty").foregroundStyle(.secondary) }
                        ForEach(events) { event in
                            Button { selectedEvent = event } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(event.title).foregroundStyle(.primary)
                                        Spacer()
                                        Text(event.visibility.localizedKey).font(.caption).foregroundStyle(.secondary)
                                    }
                                    SharedEventTimeView(start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
                                        .font(.caption).foregroundStyle(.secondary)
                                    if event.override != nil || event.seriesOverride != nil {
                                        Label("sharing.events.customVisibility", systemImage: "eye").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(manager.isBusy || profile.pendingDeletion)
                        }
                    } header: { Text("sharing.events.title") }
                    footer: { Text("sharing.events.localOnly") }

                    Section {
                        Button(role: .destructive) { showingDelete = true } label: {
                            Text(profile.pendingDeletion ? LocalizedStringKey("sharing.delete.retry") : LocalizedStringKey("sharing.delete.action"))
                        }
                        .disabled(manager.isBusy)
                    } footer: { Text("sharing.target.help") }
                }
                .navigationTitle(profile.name)
                .refreshable { manager.refresh(); await reload() }
                .task(id: profile.revision) { await reload() }
                .onChange(of: profile.lastError) { _, _ in manager.refresh() }
                .sheet(isPresented: $showingEditor, onDismiss: { Task { await reload() } }) {
                    NavigationStack { SharedCalendarEditorView(profile: profile, defaultSourceIDs: [], defaultPrivacyMode: profile.privacyMode) }
                }
                .sheet(isPresented: $showingGuide) {
                    NavigationStack {
                        SharedCalendarGuideView(calendarName: manager.calendars.first { $0.id == profile.targetCalendarID }?.title ?? EventKitCalendarStore.namePrefix + profile.name)
                    }
                }
                .sheet(item: $selectedEvent, onDismiss: { Task { await reload() } }) { event in
                    NavigationStack { SharedEventVisibilityView(profileID: profileID, event: event) }
                }
            } else {
                ContentUnavailableView("sharing.unavailable", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .alert("sharing.delete.title", isPresented: $showingDelete) {
            Button("common.delete", role: .destructive) {
                Task {
                    do { try await manager.delete(profileID: profileID); dismiss() }
                    catch { operationError = error.localizedDescription }
                }
            }
            Button("common.cancel", role: .cancel) { }
        } message: { Text("sharing.delete.message") }
        .alert("sharing.recreate.title", isPresented: $showingRecreate) {
            Button("sharing.recreate.action") {
                Task {
                    do {
                        try await manager.recreateTarget(profileID: profileID)
                        await reload()
                        showingGuide = true
                    } catch { operationError = error.localizedDescription }
                }
            }
            Button("common.cancel", role: .cancel) { }
        } message: { Text("sharing.recreate.message") }
        .sharingErrorAlert($operationError)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do { events = try await manager.preview(profileID: profileID) }
        catch { events = []; operationError = error.localizedDescription }
    }
}

struct SharedRangeSummary: View {
    @Environment(\.locale) private var locale
    let range: SharedCalendarRange
    var body: some View {
        switch range {
        case .rolling(let past, let future, _):
            VStack(alignment: .leading, spacing: 4) {
                Text("sharing.range.rolling")
                HStack(spacing: 4) {
                    Text("sharing.range.pastDays"); Text(past, format: .number)
                    Text("·")
                    Text("sharing.range.futureDays"); Text(future, format: .number)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        case .fixed(let start, let end, let zone):
            let calendar = calendarInTimeZone(zone)
            VStack(alignment: .leading, spacing: 4) {
                Text("sharing.range.fixed")
                Text("\(formattedDate(start, zone: zone)) – \(formattedDate(calendar.date(byAdding: .day, value: -1, to: end) ?? end, zone: zone))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func formattedDate(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: zone) ?? .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

struct SharedEventVisibilityView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    @EnvironmentObject private var workspace: SharingWorkspace
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID
    let event: SharedEventPreview
    @State private var entireSeries = false
    @State private var selection = "inherit"
    @State private var baseRevision = 0
    @State private var isEditing = false
    @State private var hasLoaded = false
    @State private var showingClose = false
    @State private var showingReview = false
    @State private var showingCalendarEditor = false
    @State private var savedDraftExists = false
    @State private var publicationCompleted = false

    private var profile: SharedCalendarProfile? { manager.profiles.first { $0.id == profileID } }
    private var isWithinSharingScope: Bool {
        switch event.membership {
        case .outsideDateRange, .outsideSources: return false
        case .confirmed, .excluded: return true
        }
    }
    private var isStale: Bool { profile?.revision != baseRevision }
    private var hasChanges: Bool {
        isEditing && selection != ((entireSeries ? event.seriesOverride : event.override)?.rawValue ?? "inherit")
    }
    private var effectiveVisibility: SharedVisibility {
        guard isEditing else { return event.visibility }
        let selected = SharedVisibility(rawValue: selection)
        let inherited = SharedVisibility(privacyMode: profile?.privacyMode ?? event.defaultPrivacyMode)
        if entireSeries { return event.override ?? selected ?? inherited }
        return selected ?? (event.isRecurring ? event.seriesOverride : nil) ?? inherited
    }
    private var livePreview: PublishedEvent? {
        guard isWithinSharingScope else { return nil }
        guard isEditing else { return event.published }
        guard let source = event.source else { return nil }
        return PublishedEvent(source: source, visibility: effectiveVisibility)
    }
    private var eventDraft: SharedEventVisibilityDraft {
        SharedEventVisibilityDraft(profileID: profileID, identityID: event.identityID, occurrenceKey: event.occurrenceKey,
            entireSeries: entireSeries, visibility: SharedVisibility(rawValue: selection), baseRevision: baseRevision)
    }

    var body: some View {
        Form {
            Section("sharing.events.source") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.title).font(.headline).accessibilityIdentifier("sharing.event.original.title")
                    SharedEventTimeView(start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if event.source?.location?.isEmpty == false || event.source?.notes?.isEmpty == false {
                    DisclosureGroup("detail.info") {
                        if let location = event.source?.location, !location.isEmpty { Label(location, systemImage: "location") }
                        if let notes = event.source?.notes, !notes.isEmpty { Text(notes) }
                    }
                    .accessibilityIdentifier("sharing.event.original.details")
                }
            }
            if isEditing {
                Section {
                    if event.isRecurring {
                        Picker("sharing.override.scope", selection: $entireSeries) {
                            Text("sharing.override.occurrence").tag(false)
                            Text("sharing.override.series").tag(true)
                        }
                        .accessibilityIdentifier("sharing.event.scope")
                        .onChange(of: entireSeries) { _, series in selection = (series ? event.seriesOverride : event.override)?.rawValue ?? "inherit" }
                    }
                    Picker("sharing.override.visibility", selection: $selection) {
                        Text("sharing.visibility.inherit").tag("inherit").accessibilityIdentifier("sharing.event.visibility.inherit")
                        ForEach(SharedVisibility.allCases) { visibility in
                            Text(visibility.localizedKey).tag(visibility.rawValue)
                                .accessibilityIdentifier("sharing.event.visibility.\(visibility.rawValue)")
                        }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } header: { Text("sharing.override.visibility") }
                footer: { Text("sharing.draft.localOnly") }
                if isStale {
                    Section {
                        Label("sharing.event.stale.help", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("sharing.event.reload") { restartEditing() }
                            .accessibilityIdentifier("sharing.event.reload")
                    }
                }
            }
            Section {
                SharedPublishedEventPreview(published: livePreview)
                if isEditing && entireSeries && event.override != nil {
                    Text("sharing.preview.occurrenceWins").font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text(isEditing ? LocalizedStringKey("sharing.preview.proposed") : LocalizedStringKey("sharing.preview.title")) }
            footer: { Text(isEditing ? LocalizedStringKey("sharing.draft.localOnly") : LocalizedStringKey("sharing.preview.confirmed")) }

            if !isWithinSharingScope {
                Section {
                    Label(event.membership == .outsideSources ? LocalizedStringKey("browse.reason.source") : LocalizedStringKey("browse.reason.date"), systemImage: "eye.slash")
                    Button("sharing.action.edit") { showingCalendarEditor = true }
                        .accessibilityIdentifier("sharing.event.editRules")
                } footer: { Text("sharing.event.outside.help") }
            } else if event.source == nil {
                Section {
                    Label("sharing.event.snapshotMissing", systemImage: "arrow.clockwise").foregroundStyle(.secondary)
                    Button("sharing.event.return") { dismiss() }
                }
            } else if !isEditing {
                Section {
                    Button(savedDraftExists ? LocalizedStringKey("sharing.draft.resume") : LocalizedStringKey("sharing.event.modify")) { isEditing = true }
                        .accessibilityIdentifier("sharing.event.modify")
                }
            }
        }
        .disabled(manager.isBusy)
        .navigationTitle("sharing.override.title")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isEditing ? LocalizedStringKey("common.cancel") : LocalizedStringKey("common.done")) { close() }
                    .disabled(manager.isBusy).accessibilityIdentifier("sharing.event.cancel")
            }
            if isEditing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("sharing.review.action") { persistDraft(); showingReview = true }
                        .disabled(manager.isBusy || isStale || !hasChanges || event.source == nil).accessibilityIdentifier("sharing.event.save")
                }
            }
        }
        .interactiveDismissDisabled(isEditing || manager.isBusy)
        .task {
            guard !hasLoaded else { return }
            baseRevision = profile?.revision ?? 0
            selection = event.override?.rawValue ?? "inherit"
            if let saved = workspace.eventDraft(profileID: profileID, identityID: event.identityID, occurrenceKey: event.occurrenceKey) {
                entireSeries = saved.entireSeries
                selection = saved.visibility?.rawValue ?? "inherit"
                baseRevision = saved.baseRevision
                savedDraftExists = true
            }
            hasLoaded = true
        }
        .onChange(of: selection) { _, _ in if hasLoaded && isEditing { persistDraft() } }
        .onChange(of: entireSeries) { _, _ in if hasLoaded && isEditing { persistDraft() } }
        .sheet(isPresented: $showingReview, onDismiss: { if publicationCompleted { dismiss() } }) {
            NavigationStack {
                SharedEventVisibilityReviewView(event: event, draft: eventDraft, preview: livePreview) {
                    publicationCompleted = true
                    showingReview = false
                }
            }
        }
        .sheet(isPresented: $showingCalendarEditor, onDismiss: { dismiss() }) {
            if let profile {
                NavigationStack { SharedCalendarEditorView(profile: profile, defaultSourceIDs: profile.sourceCalendarIDs, defaultPrivacyMode: profile.privacyMode) }
            }
        }
        .confirmationDialog("sharing.draft.close.title", isPresented: $showingClose, titleVisibility: .visible) {
            Button("sharing.draft.keep") { persistDraft(); dismiss() }
            Button("sharing.draft.discard", role: .destructive) { discardDraft(); dismiss() }
            Button("sharing.draft.continue", role: .cancel) { }
        } message: { Text("sharing.draft.close.message") }
    }

    private func persistDraft() {
        if hasChanges { workspace.saveEventDraft(eventDraft); savedDraftExists = true }
        else { discardDraft() }
    }
    private func discardDraft() {
        workspace.discardEventDraft(profileID: profileID, identityID: event.identityID, occurrenceKey: event.occurrenceKey)
        savedDraftExists = false
    }
    private func restartEditing() {
        discardDraft()
        dismiss()
    }
    private func close() {
        if hasChanges || (isEditing && savedDraftExists) { showingClose = true }
        else { dismiss() }
    }
}

private struct SharedEventVisibilityReviewView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    @EnvironmentObject private var workspace: SharingWorkspace
    @Environment(\.dismiss) private var dismiss
    let event: SharedEventPreview
    let draft: SharedEventVisibilityDraft
    let preview: PublishedEvent?
    let onCompleted: () -> Void
    @State private var isPublishing = false
    @State private var operationError: String?
    @State private var savedBeforeFailure = false
    private var profile: SharedCalendarProfile? { manager.profiles.first { $0.id == draft.profileID } }

    var body: some View {
        List {
            if let profile { SharedCalendarReviewSummary(profile: profile) }
            Section("sharing.override.scope") {
                Text(draft.entireSeries ? LocalizedStringKey("sharing.override.series") : LocalizedStringKey("sharing.override.occurrence"))
                LabeledContent("sharing.override.visibility") { Text(draft.visibility?.localizedKey ?? LocalizedStringKey("sharing.visibility.inherit")) }
                if draft.entireSeries { Text("sharing.event.series.help").font(.caption).foregroundStyle(.secondary) }
            }
            Section("sharing.review.before") { SharedPublishedEventPreview(published: event.published) }
            Section("sharing.review.after") { SharedPublishedEventPreview(published: preview) }
            if profile?.isPaused == true { Section { Text("sharing.review.paused").foregroundStyle(.secondary) } }
            Section {
                Button { Task { await publish() } } label: { Text("sharing.review.confirmUpdate").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(isPublishing || manager.isBusy || profile == nil)
                    .accessibilityIdentifier("sharing.event.confirm")
            } footer: { Text("sharing.event.confirm.help") }
        }
        .navigationTitle("sharing.review.title")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("sharing.review.back") { dismiss() }.disabled(isPublishing) } }
        .interactiveDismissDisabled(isPublishing)
        .alert(Text(savedBeforeFailure ? LocalizedStringKey("sharing.save.savedTitle") : LocalizedStringKey("sharing.error.title")), isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("common.done") { if savedBeforeFailure { onCompleted() } }
        } message: {
            if savedBeforeFailure { Text("sharing.save.savedNotPublished") + Text("\n\n") + Text(operationError ?? "") }
            else { Text(operationError ?? "") }
        }
    }
    private func publish() async {
        guard !isPublishing, !manager.isBusy else { return }
        isPublishing = true
        defer { isPublishing = false }
        let previousRevision = profile?.revision
        do {
            try await manager.setVisibility(profileID: draft.profileID, event: event, visibility: draft.visibility,
                entireSeries: draft.entireSeries, expectedRevision: draft.baseRevision)
            workspace.discardEventDraft(profileID: draft.profileID, identityID: draft.identityID, occurrenceKey: draft.occurrenceKey)
            onCompleted()
        } catch {
            savedBeforeFailure = previousRevision != nil && profile?.revision != nil && profile?.revision != previousRevision
            if savedBeforeFailure { workspace.discardEventDraft(profileID: draft.profileID, identityID: draft.identityID, occurrenceKey: draft.occurrenceKey) }
            operationError = error.localizedDescription
        }
    }
}

struct SharedPublishedEventPreview: View {
    let published: PublishedEvent?
    var body: some View {
        if let published {
            VStack(alignment: .leading, spacing: 8) {
                Text(published.title).font(.headline).accessibilityIdentifier("sharing.event.preview.title")
                SharedEventTimeView(start: published.startDate, end: published.endDate, isAllDay: published.isAllDay)
                    .font(.subheadline).foregroundStyle(.secondary)
                if let location = published.location, !location.isEmpty { Label(location, systemImage: "location").accessibilityIdentifier("sharing.event.preview.location") }
                if let notes = published.notes, !notes.isEmpty { Text(notes).accessibilityIdentifier("sharing.event.preview.notes") }
            }
            .padding(.vertical, 4)
        } else {
            Label("sharing.visibility.excluded", systemImage: "eye.slash").foregroundStyle(.secondary)
                .accessibilityIdentifier("sharing.event.preview.excluded")
        }
    }
}

struct SharedCalendarGuideView: View {
    @Environment(\.dismiss) private var dismiss
    let calendarName: String

    var body: some View {
        List {
            Section {
                Text(calendarName).font(.headline)
                Text("sharing.guide.intro")
            }
            Section("sharing.guide.public.title") {
                Text("sharing.guide.public.steps")
            }
            Section("sharing.guide.private.title") {
                Text("sharing.guide.private.steps")
            }
            Section {
                Text("sharing.guide.revoke")
                Link("sharing.guide.apple", destination: URL(string: "https://support.apple.com/guide/iphone/share-icloud-calendars-iph7613c4fb/ios")!)
            }
        }
        .navigationTitle("sharing.guide.title")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } } }
    }
}

struct SharedEventTimeView: View {
    @Environment(\.timeZone) private var timeZone
    let start: Date
    let end: Date
    let isAllDay: Bool
    var body: some View {
        if isAllDay {
            let calendar = calendarInTimeZone(timeZone.identifier)
            let finalDay = max(start, calendar.date(byAdding: .day, value: -1, to: end) ?? start)
            HStack(spacing: 5) {
                Text(start, format: .dateTime.year().month().day())
                if !calendar.isDate(start, inSameDayAs: finalDay) {
                    Text("–")
                    Text(finalDay, format: .dateTime.year().month().day())
                }
                Text("event.allDay").foregroundStyle(.secondary)
            }
        } else {
            let calendar = calendarInTimeZone(timeZone.identifier)
            if calendar.isDate(start, inSameDayAs: end) {
                Text(start, format: .dateTime.month().day().hour().minute()) + Text(" – ") + Text(end, format: .dateTime.hour().minute())
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(start, format: .dateTime.year().month().day().hour().minute())
                    Text(end, format: .dateTime.year().month().day().hour().minute())
                }
            }
        }
    }
}

extension SharedVisibility {
    var localizedKey: LocalizedStringKey {
        switch self {
        case .excluded: return "sharing.visibility.excluded"
        case .opaque: return "privacy.opaque"
        case .partial: return "privacy.partial"
        case .full: return "privacy.full"
        }
    }
}

func calendarInTimeZone(_ identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier) ?? .current
    return calendar
}

private struct SharingErrorAlert: ViewModifier {
    @Binding var error: String?
    func body(content: Content) -> some View {
        content.alert("sharing.error.title", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.done", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

extension View {
    func sharingErrorAlert(_ error: Binding<String?>) -> some View { modifier(SharingErrorAlert(error: error)) }
}
