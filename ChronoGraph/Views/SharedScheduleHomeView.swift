import SwiftUI

/// Shared schedules use the same list and interaction surfaces as personal schedules.
struct SharedScheduleHomeView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    let profile: SharedCalendarProfile?
    let defaultSourceIDs: Set<String>
    let defaultPrivacyMode: PrivacyMode
    let collapseEmptyDays: Bool
    let onPreviewChange: (String, [SharedEventPreview]?) -> Void
    @State private var events: [SharedEventPreview] = []
    @State private var eventsProfileID: UUID?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showingCreate = false
    @State private var showsExcluded = false
    @State private var selectedEvent: SharedEventPreview?
    @State private var loadToken = UUID()

    private var previewVersion: String {
        guard let profile else { return "empty" }
        return "\(profile.id)-\(profile.revision)-\(profile.lastUpdated?.timeIntervalSince1970 ?? 0)"
    }
    private var excludedEvents: [SharedEventPreview] { events.filter { $0.published == nil } }

    var body: some View {
        Group {
            if let profile {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 20) {
                        if isLoading || eventsProfileID != profile.id {
                            ProgressView().padding()
                        } else if let loadError {
                            VStack(spacing: 12) {
                                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                                Button("common.retry") { Task { await reload() } }
                            }
                            .padding()
                        } else if let interval = try? profile.range.dateInterval() {
                            InAppEventListView(sharedEvents: events, dateInterval: interval,
                                timeZone: TimeZone(identifier: profile.range.timeZoneIdentifier) ?? .current,
                                collapseEmptyDays: collapseEmptyDays, onSelect: { selectedEvent = $0 })
                            if !excludedEvents.isEmpty { excludedSection }
                            if profile.isPaused || profile.lastError != nil {
                                SharedCalendarStatusView(profile: profile)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .environment(\.timeZone, TimeZone(identifier: profile.range.timeZoneIdentifier) ?? .current)
                .refreshable { manager.refresh(); await reload() }
                .sheet(item: $selectedEvent, onDismiss: { Task { await reload() } }) { event in
                    NavigationStack { SharedEventVisibilityView(profileID: profile.id, event: event) }
                        .environment(\.timeZone, TimeZone(identifier: profile.range.timeZoneIdentifier) ?? .current)
                }
            } else {
                ContentUnavailableView {
                    Label("home.noSharedCalendars", systemImage: "calendar.badge.plus")
                } description: {
                    Text("home.noSharedCalendars.description")
                } actions: {
                    Button("home.createSharedCalendar") { showingCreate = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .task(id: previewVersion) { await reload() }
        .task { manager.refresh() }
        .onChange(of: profile?.id) { _, _ in showsExcluded = false }
        .sheet(isPresented: $showingCreate) {
            NavigationStack {
                SharedCalendarEditorView(profile: nil,
                    defaultSourceIDs: defaultSourceIDs.subtracting(manager.calendars.filter(\.isManaged).map(\.id)),
                    defaultPrivacyMode: defaultPrivacyMode)
            }
        }
    }

    private var excludedSection: some View {
        DisclosureGroup(isExpanded: $showsExcluded) {
            ForEach(excludedEvents) { event in
                Button { selectedEvent = event } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.subheadline).fontWeight(.semibold)
                        SharedEventTimeView(start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Divider()
            }
        } label: {
            HStack {
                Label("home.excluded", systemImage: "eye.slash")
                Spacer()
                Text(excludedEvents.count, format: .number).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    private func reload() async {
        let token = UUID()
        loadToken = token
        let version = previewVersion
        onPreviewChange(version, nil)
        guard let profile else { events = []; eventsProfileID = nil; return }
        isLoading = true
        loadError = nil
        defer { if loadToken == token { isLoading = false } }
        do {
            let result = try await manager.preview(profileID: profile.id)
            try Task.checkCancellation()
            guard loadToken == token, previewVersion == version else { return }
            events = result
            eventsProfileID = profile.id
            onPreviewChange(version, result)
        } catch is CancellationError { }
        catch {
            guard loadToken == token else { return }
            events = []
            eventsProfileID = profile.id
            loadError = error.localizedDescription
        }
    }
}

struct SharedCalendarSourcesEditorView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    @Environment(\.dismiss) private var dismiss
    private let profileID: UUID
    @State private var sourceIDs: Set<String>
    @State private var isSaving = false
    @State private var operationError: String?
    @State private var savedBeforeFailure = false

    init(profile: SharedCalendarProfile) {
        profileID = profile.id
        _sourceIDs = State(initialValue: profile.sourceCalendarIDs)
    }

    private var available: [SharedCalendarOption] { manager.calendars.filter { !$0.isManaged } }
    private var isBusy: Bool { isSaving || manager.isBusy }

    var body: some View {
        List {
            Section {
                ForEach(available) { calendar in
                    Button {
                        if !sourceIDs.insert(calendar.id).inserted { sourceIDs.remove(calendar.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(calendar.title).foregroundStyle(.primary)
                                Text(calendar.sourceTitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if sourceIDs.contains(calendar.id) { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("sharing.sources.source.\(calendar.id)")
                    .accessibilityAddTraits(sourceIDs.contains(calendar.id) ? .isSelected : [])
                }
                if available.isEmpty { Text("calendars.empty").foregroundStyle(.secondary) }
            } footer: { Text("home.sources.help") }
            Section {
                Button("calendars.selectAll") { sourceIDs.formUnion(available.map(\.id)) }
                Button("calendars.clear") { sourceIDs.removeAll() }
            }
            let unavailableIDs = sourceIDs.subtracting(available.map(\.id))
            if !unavailableIDs.isEmpty {
                Section {
                    Label("sharing.sources.unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("sharing.sources.removeUnavailable") { sourceIDs.subtract(unavailableIDs) }
                }
            }
        }
        .disabled(isBusy)
        .navigationTitle("home.sharedSources")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.disabled(isBusy) }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.save") { Task { await save() } }.disabled(isBusy)
                    .accessibilityIdentifier("sharing.sources.save")
            }
        }
        .interactiveDismissDisabled(isBusy)
        .alert(Text(savedBeforeFailure ? LocalizedStringKey("sharing.save.savedTitle") : LocalizedStringKey("sharing.error.title")), isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("common.done") { if savedBeforeFailure { dismiss() } }
        } message: {
            if savedBeforeFailure { Text("sharing.save.savedNotPublished") + Text("\n\n") + Text(operationError ?? "") }
            else { Text(operationError ?? "") }
        }
    }

    private func save() async {
        guard !isBusy else { return }
        isSaving = true
        defer { isSaving = false }
        let revision = manager.profiles.first { $0.id == profileID }?.revision
        do {
            try await manager.updateSources(profileID: profileID, sourceCalendarIDs: sourceIDs)
            dismiss()
        } catch {
            let latest = manager.profiles.first { $0.id == profileID }
            savedBeforeFailure = revision != nil && latest?.revision != revision && latest?.sourceCalendarIDs == sourceIDs
            operationError = error.localizedDescription
        }
    }
}
