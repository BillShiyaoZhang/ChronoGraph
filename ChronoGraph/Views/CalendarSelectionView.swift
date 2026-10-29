// filepath: /Users/shiyaozhang/Developer/ChronoGraph/ChronoGraph/Views/CalendarSelectionView.swift
import SwiftUI
import EventKit

struct CalendarSelectionView: View {
    @ObservedObject var calendarManager: CalendarManager
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    let cloudIsLoading: Bool
    let cloudError: String?
    let onRefresh: (() async -> Void)?
    @State private var collapsedSources: Set<String> = []
    @State private var removingSource: CloudSharedSource?

    init(calendarManager: CalendarManager, cloudIsLoading: Bool = false, cloudError: String? = nil,
         onRefresh: (() async -> Void)? = nil) {
        _calendarManager = ObservedObject(wrappedValue: calendarManager)
        self.cloudIsLoading = cloudIsLoading
        self.cloudError = cloudError
        self.onRefresh = onRefresh
    }

    private var groupedCalendars: [CalendarDisplayGrouping.Group] {
        CalendarDisplayGrouping.groups(calendarManager.calendars.map {
            .init(id: $0.calendarIdentifier, title: $0.title,
                  sourceID: $0.source.sourceIdentifier, sourceTitle: $0.source.title)
        })
    }
    private var ownedCloudSources: [CloudSharedSource] { cloud.displaySources.filter { $0.ownerId == cloud.currentUserID } }
    private var receivedCloudRows: [CloudReceivedCalendarRow] {
        CloudReceivedCalendarRow.rows(cloud.displaySources.filter { $0.ownerId != cloud.currentUserID })
    }

    var body: some View {
        List {
            cloudSection
            if calendarManager.calendars.isEmpty {
                Section { Text("calendars.local.empty").foregroundColor(.secondary) }
            } else {
                ForEach(groupedCalendars) { group in
                    Section {
                        if !collapsedSources.contains(group.id) {
                            ForEach(calendars(in: group), id: \.calendarIdentifier) { cal in
                                calendarRow(cal)
                            }
                        }
                    } header: { groupHeader(group) }
                }
                Section { Text("calendars.serviceManagement").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.easeInOut, value: collapsedSources)
        .navigationTitle("calendars.selectTitle")
        .toolbar { toolbarContent }
        .refreshable { await onRefresh?() }
        .modifier(CalendarsChangeModifier(calendars: calendarManager.calendars) { pruneCollapsed() })
        .sheet(item: $removingSource) { source in
            NavigationStack { CloudReceivedCalendarRemovalView(source: source) }
        }
        .onChange(of: cloud.homeDisplayScope) { _, _ in removingSource = nil }
        .onChange(of: cloud.session?.accessToken) { _, _ in removingSource = nil }
    }

    private var cloudSection: some View {
        Section {
            if cloud.session == nil {
                Text("cloud.home.signInHint").foregroundStyle(.secondary)
            } else {
                if cloudIsLoading { ProgressView("cloud.home.loading").accessibilityIdentifier("cloud.home.loading") }
                if let cloudError {
                    Text(cloudError).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("cloud.home.error")
                    if let onRefresh {
                        Button("cloud.home.retry") { Task { await onRefresh() } }
                            .disabled(cloudIsLoading).accessibilityIdentifier("cloud.home.retry")
                    }
                }
                Text("cloud.home.owned").font(.subheadline.bold()).accessibilityIdentifier("cloud.home.owned.group")
                if ownedCloudSources.isEmpty && !cloudIsLoading && cloudError == nil {
                    Text("cloud.home.owned.empty").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("cloud.home.owned.empty")
                }
                ForEach(ownedCloudSources) { cloudCalendarRow($0, isOwned: true) }
                Text("cloud.home.received").font(.subheadline.bold()).accessibilityIdentifier("cloud.home.received.group")
                if receivedCloudRows.isEmpty && !cloudIsLoading && cloudError == nil {
                    Text("cloud.home.noSources").font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("cloud.home.received.empty")
                }
                ForEach(receivedCloudRows) { row in
                    switch row {
                    case let .owner(id, name):
                        Text(name).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("cloud.home.received.owner.\(id.uuidString)")
                    case let .calendar(source):
                        cloudCalendarRow(source, isOwned: false)
                            .contextMenu { removeAction(source) }
                            .swipeActions(allowsFullSwipe: false) {
                                // This action opens review; only its final confirmation removes a row.
                                Button("cloud.received.remove.title") { removingSource = source }
                                    .tint(.red)
                                    .accessibilityIdentifier("cloud.received.remove.\(source.id.uuidString)")
                            }
                    }
                }
            }
            NavigationLink {
                if cloud.session != nil { CloudReceivedCalendarsView() }
                else { CloudWorkspaceView() }
            } label: { Label("cloud.home.manage", systemImage: "icloud") }
                .accessibilityIdentifier("cloud.home.manage")
        } header: { Text("cloud.home.group").accessibilityIdentifier("cloud.home.group") }
        footer: { Text("cloud.home.selectionHint") }
    }

    private func groupHeader(_ group: CalendarDisplayGrouping.Group) -> some View {
        let collapsed = collapsedSources.contains(group.id)
        return Button(action: { toggleGroup(group.id) }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title).font(.headline)
                    if let index = group.duplicateTitleIndex { Text("calendars.account.number \(index)").font(.caption) }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundColor(.secondary)
                    .animation(.easeInOut(duration: 0.18), value: collapsed)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendars.group.\(group.id)")
        .accessibilityLabel(Text(group.title + " ")
            + (group.duplicateTitleIndex.map { Text("calendars.account.number \($0)") + Text(" ") } ?? Text(""))
            + Text(collapsed ? "calendars.group.collapsedSuffix" : "calendars.group.expandedSuffix"))
    }

    private func calendarRow(_ cal: EKCalendar) -> some View {
        let selected = calendarManager.selectedCalendars.contains(cal.calendarIdentifier)
        let kind = CalendarDisplayGrouping.kind(isManaged: calendarManager.managedCalendarIDs.contains(cal.calendarIdentifier),
                                               isSubscribed: cal.isSubscribed, allowsContentModifications: cal.allowsContentModifications)
        return Button { calendarManager.toggleCalendarSelection(cal.calendarIdentifier) } label: {
            HStack {
                Circle().fill(Color(cgColor: cal.cgColor)).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cal.title)
                    if let key = kind.labelKey { Text(LocalizedStringKey(key)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
        }
        .foregroundColor(.primary)
        .contentShape(Rectangle())
        .accessibilityIdentifier("calendars.source.\(cal.calendarIdentifier)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(Text(cal.title + " ") +
            (kind.labelKey.map { Text(LocalizedStringKey($0)) + Text(" ") } ?? Text("")) +
            Text(selected ? "calendars.row.selectedSuffix" : "calendars.row.unselectedSuffix"))
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !calendarManager.calendars.isEmpty || !cloud.displaySources.isEmpty {
                Button("calendars.selectAll") { selectAll() }
                Button("calendars.clear") { clearAll() }
            }
        }
    }

    private func selectAll() {
        calendarManager.selectAllDefaultCalendars()
        cloud.selectAllDisplaySources()
    }
    private func clearAll() {
        calendarManager.selectedCalendars.removeAll()
        calendarManager.loadEvents()
        cloud.clearDisplaySourceSelection()
    }

    private func cloudCalendarRow(_ source: CloudSharedSource, isOwned: Bool) -> some View {
        let selected = cloud.selectedDisplaySourceIDs.contains(source.id)
        return Button { cloud.toggleDisplaySource(source.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "icloud").foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name)
                    (Text("cloud.home.maximumDetails") + Text(" · " + source.privacy.label)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cloud.home.\(isOwned ? "owned" : "source").\(source.id.uuidString)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func removeAction(_ source: CloudSharedSource) -> some View {
        Button("cloud.received.remove.title", role: .destructive) { removingSource = source }
            .accessibilityIdentifier("cloud.received.remove.\(source.id.uuidString)")
    }
    
    // MARK: - Group Helpers
    private func calendars(in group: CalendarDisplayGrouping.Group) -> [EKCalendar] {
        let calendars = Dictionary(uniqueKeysWithValues: calendarManager.calendars.map { ($0.calendarIdentifier, $0) })
        return group.calendarIDs.compactMap { calendars[$0] }
    }
    private func toggleGroup(_ source: String) {
        if collapsedSources.contains(source) { collapsedSources.remove(source) } else { collapsedSources.insert(source) }
    }
    private func pruneCollapsed() {
        let existing = Set(groupedCalendars.map(\.id))
        collapsedSources = collapsedSources.intersection(existing)
    }
}

// Helper view modifier to handle iOS 17 onChange API changes
private struct CalendarsChangeModifier: ViewModifier {
    let calendars: [EKCalendar]
    let action: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.onChange(of: calendars) { _, _ in action() }
        } else {
            content.onChange(of: calendars) { _ in action() }
        }
    }
}

#Preview { CalendarSelectionView(calendarManager: CalendarManager()).environmentObject(CloudWorkspaceManager()) }
