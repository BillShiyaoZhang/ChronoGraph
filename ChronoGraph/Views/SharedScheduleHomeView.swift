import SwiftUI

/// Browsing only reads source events. Confirmed rules remain the sole input to the publisher.
struct SharedScheduleHomeView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    @EnvironmentObject private var workspace: SharingWorkspace
    let profile: SharedCalendarProfile?
    let browse: ShareBrowseSettings?
    let collapseEmptyDays: Bool
    let onCreate: ()->Void
    let onEdit: ()->Void
    let onPreviewChange: ([SharedEventPreview])->Void
    @State private var events: [SharedEventPreview] = []
    @State private var loadedKey: LoadKey?
    @State private var loadError: String?
    @State private var selectedEvent: SharedEventPreview?
    @State private var requestID = UUID()
    @State private var refreshID = UUID()

    private struct LoadKey: Equatable {
        var profileID: UUID?
        var revision: Int?
        var lastUpdated: Date?
        var browse: ShareBrowseSettings?
        var refreshID: UUID
    }
    private var key: LoadKey {
        LoadKey(profileID: profile?.id, revision: profile?.revision,
                lastUpdated: profile?.lastUpdated, browse: browse, refreshID: refreshID)
    }
    private var differs: Bool {
        guard let profile, let browse else { return false }
        return browse.range != profile.range || browse.sourceCalendarIDs != profile.sourceCalendarIDs || browse.displayMode != nil
    }

    private var scopeDiffers: Bool {
        guard let profile, let browse else { return false }
        return browse.range != profile.range || browse.sourceCalendarIDs != profile.sourceCalendarIDs
    }

    private var hasRuleDraft: Bool { profile.flatMap { workspace.draft(profileID: $0.id) } != nil }

    private var sharingEntry: some View {
        Button(action: onEdit) {
            HStack(spacing: 8) {
                Image(systemName: differs ? "iphone" : "person.2").accessibilityHidden(true)
                Text(differs ? LocalizedStringKey("browse.localOnly") : LocalizedStringKey("browse.sharedRules"))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(differs ? "home.browse.localOnly" : "home.sharing.confirmed")
                Spacer(minLength: 8)
                Text(scopeDiffers ? LocalizedStringKey("browse.reviewScope") : hasRuleDraft ? LocalizedStringKey("sharing.draft.resume") : LocalizedStringKey("sharing.action.edit"))
                    .foregroundStyle(.tint)
                Image(systemName: "chevron.forward").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .font(.caption)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.isBusy)
        .accessibilityIdentifier("home.sharing.status")
    }

    var body: some View {
        Group {
            if let profile, let browse {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        sharingEntry
                        if loadedKey != key { ProgressView().padding() }
                        else if let loadError {
                            VStack(spacing: 12) {
                                Text(loadError).foregroundStyle(.secondary)
                                Button("common.retry") { refreshID = UUID() }
                            }.padding()
                        } else if let interval = try? browse.range.dateInterval() {
                            InAppEventListView(sharedEvents: events, dateInterval: interval,
                                timeZone: TimeZone(identifier: browse.range.timeZoneIdentifier) ?? .current,
                                collapseEmptyDays: collapseEmptyDays, displayMode: browse.displayMode,
                                showsUnshared: true, onSelect: { selectedEvent = $0 })
                            if profile.isPaused || profile.lastError != nil {
                                SharedCalendarStatusView(profile: profile).padding(.horizontal)
                            }
                        }
                    }.padding(.top, 4)
                }
                .environment(\.timeZone, TimeZone(identifier: browse.range.timeZoneIdentifier) ?? .current)
                .refreshable { manager.refresh(); refreshID = UUID() }
                .sheet(item: $selectedEvent, onDismiss: { refreshID = UUID() }) { event in
                    NavigationStack { SharedEventVisibilityView(profileID: profile.id, event: event) }
                }
            } else {
                ContentUnavailableView {
                    Label("home.noSharedCalendars", systemImage: "calendar.badge.plus")
                } description: { Text("home.noSharedCalendars.description") }
                actions: { Button("home.createSharedCalendar", action: onCreate).buttonStyle(.borderedProminent) }
            }
        }
        .task(id: key) { await reload() }
        .task { manager.refresh() }
    }

    private func reload() async {
        let request = UUID(); requestID = request
        let version = key
        loadError = nil
        onPreviewChange([])
        guard let profile, let browse else { events = []; loadedKey = version; return }
        do {
            let result = try await manager.browsePreview(profileID: profile.id, range: browse.range,
                sourceCalendarIDs: browse.sourceCalendarIDs, displayMode: browse.displayMode)
            try Task.checkCancellation()
            guard requestID == request else { return }
            events = result; loadedKey = version
            onPreviewChange(result)
        } catch is CancellationError { }
        catch {
            guard requestID == request else { return }
            events = []; loadedKey = version; loadError = error.localizedDescription
        }
    }
}

struct BrowseCalendarSelectionView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    @State private var selectedIDs: Set<String>
    let onChange: (Set<String>)->Void
    init(selectedIDs: Set<String>, onChange: @escaping (Set<String>)->Void) {
        _selectedIDs = State(initialValue: selectedIDs); self.onChange = onChange
    }
    private var available: [SharedCalendarOption] { manager.calendars.filter { !$0.isManaged } }
    var body: some View {
        List {
            Section {
                ForEach(available) { calendar in
                    Button {
                        if !selectedIDs.insert(calendar.id).inserted { selectedIDs.remove(calendar.id) }
                        onChange(selectedIDs)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(calendar.title).foregroundStyle(.primary)
                                Text(calendar.sourceTitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedIDs.contains(calendar.id) { Image(systemName: "checkmark") }
                        }.contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("browse.sources.\(calendar.id)")
                    .accessibilityAddTraits(selectedIDs.contains(calendar.id) ? .isSelected : [])
                }
            } footer: { Text("browse.sources.help") }
        }
        .navigationTitle("settings.calendars")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("calendars.selectAll") { selectedIDs = Set(available.map(\.id)); onChange(selectedIDs) }
                Button("calendars.clear") { selectedIDs = []; onChange(selectedIDs) }
            }
        }
        .task { manager.refresh() }
    }
}
