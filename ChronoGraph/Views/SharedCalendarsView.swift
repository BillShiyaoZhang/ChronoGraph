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
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID
    let event: SharedEventPreview
    @State private var entireSeries = false
    @State private var selection: String
    @State private var operationError: String?
    @State private var isSaving = false
    @State private var savedBeforeFailure = false

    init(profileID: UUID, event: SharedEventPreview) {
        self.profileID = profileID
        self.event = event
        _selection = State(initialValue: event.override?.rawValue ?? "inherit")
    }

    private var isBusy: Bool { isSaving || manager.isBusy }

    private var effectiveVisibility: SharedVisibility {
        let selected = SharedVisibility(rawValue: selection)
        let defaultMode = manager.profiles.first { $0.id == profileID }?.privacyMode ?? event.defaultPrivacyMode
        let inherited = SharedVisibility(privacyMode: defaultMode)
        if entireSeries { return event.override ?? selected ?? inherited }
        return selected ?? (event.isRecurring ? event.seriesOverride : nil) ?? inherited
    }

    private var previewSource: SourceEventSnapshot {
        event.source ?? SourceEventSnapshot(
            calendarID: "", calendarItemIdentifier: event.id, title: event.title,
            startDate: event.startDate, endDate: event.endDate,
            location: event.published?.location, notes: event.published?.notes,
            isAllDay: event.isAllDay, timeZoneIdentifier: event.published?.timeZoneIdentifier,
            availability: event.published?.availability ?? .busy
        )
    }

    private var livePreview: PublishedEvent? { PublishedEvent(source: previewSource, visibility: effectiveVisibility) }

    var body: some View {
        Form {
            Section("sharing.events.source") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(event.title).font(.headline)
                        .accessibilityIdentifier("sharing.event.original.title")
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
                    Text("sharing.visibility.inherit")
                        .tag("inherit")
                        .accessibilityIdentifier("sharing.event.visibility.inherit")
                    ForEach(SharedVisibility.allCases) { visibility in
                        Text(visibility.localizedKey)
                            .tag(visibility.rawValue)
                            .accessibilityIdentifier("sharing.event.visibility.\(visibility.rawValue)")
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: { Text("sharing.override.visibility") }
            footer: { Text("sharing.override.help") }
            Section {
                if let published = livePreview {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(published.title).font(.headline)
                            .accessibilityIdentifier("sharing.event.preview.title")
                        SharedEventTimeView(start: published.startDate, end: published.endDate, isAllDay: published.isAllDay)
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let location = published.location, !location.isEmpty {
                            Label(location, systemImage: "location").accessibilityIdentifier("sharing.event.preview.location")
                        }
                        if let notes = published.notes, !notes.isEmpty {
                            Text(notes).accessibilityIdentifier("sharing.event.preview.notes")
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Label("sharing.visibility.excluded", systemImage: "eye.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("sharing.event.preview.excluded")
                }
                if entireSeries && event.override != nil {
                    Text("sharing.preview.occurrenceWins").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("sharing.preview.title")
            } footer: {
                Text("sharing.preview.live")
            }
        }
        .disabled(isBusy)
        .navigationTitle("sharing.override.title")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { dismiss() }
                    .disabled(isBusy)
                    .accessibilityIdentifier("sharing.event.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.save") { Task { await save() } }
                    .disabled(isBusy)
                    .accessibilityIdentifier("sharing.event.save")
            }
        }
        .interactiveDismissDisabled(isBusy)
        .alert(Text(savedBeforeFailure ? LocalizedStringKey("sharing.save.savedTitle") : LocalizedStringKey("sharing.error.title")), isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("common.done") { if savedBeforeFailure { dismiss() } }
        } message: {
            if savedBeforeFailure {
                Text("sharing.save.savedNotPublished") + Text("\n\n") + Text(operationError ?? "")
            } else { Text(operationError ?? "") }
        }
    }

    private func save() async {
        guard !isBusy else { return }
        isSaving = true
        defer { isSaving = false }
        let previousRevision = manager.profiles.first { $0.id == profileID }?.revision
        do {
            try await manager.setVisibility(profileID: profileID, event: event, visibility: SharedVisibility(rawValue: selection), entireSeries: entireSeries)
            dismiss()
        } catch {
            let currentRevision = manager.profiles.first { $0.id == profileID }?.revision
            savedBeforeFailure = previousRevision != nil && currentRevision != nil && currentRevision != previousRevision
            operationError = error.localizedDescription
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
