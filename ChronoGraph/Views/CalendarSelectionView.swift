// filepath: /Users/shiyaozhang/Developer/ChronoGraph/ChronoGraph/Views/CalendarSelectionView.swift
import SwiftUI
import EventKit

struct CalendarSelectionView: View {
    @ObservedObject var calendarManager: CalendarManager
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @State private var collapsedSources: Set<String> = [] // 折叠的来源标识集合

    // 分组：按来源账户标题排序（可自定义优先级）
    private var groupedCalendars: [(source: String, calendars: [EKCalendar])] {
        let dict = Dictionary(grouping: calendarManager.calendars) { cal in cal.source.title }
        // 排序规则：常见账户优先，其余按标题
        let priority = ["iCloud": 0, "Exchange": 1, "Gmail": 2, "Yahoo": 3]
        return dict.map { (k, v) in (k, v.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) }
            .sorted { a, b in
                let pa = priority[a.source] ?? 99
                let pb = priority[b.source] ?? 99
                if pa != pb { return pa < pb }
                return a.source.localizedCaseInsensitiveCompare(b.source) == .orderedAscending
            }
    }

    var body: some View {
        List {
            if calendarManager.calendars.isEmpty {
                Section { Text("calendars.empty").foregroundColor(.secondary) }
            } else {
                ForEach(groupedCalendars, id: \.source) { group in
                    Section(header: groupHeader(group)) {
                        if !collapsedSources.contains(group.source) {
                            ForEach(group.calendars, id: \.calendarIdentifier) { cal in
                                calendarRow(cal)
                            }
                        }
                    }
                }
            }
            Section {
                if cloud.session == nil {
                    Text("cloud.home.signInHint").foregroundStyle(.secondary)
                } else if cloud.sharedSources.isEmpty {
                    Text("cloud.home.noSources").foregroundStyle(.secondary)
                } else {
                    ForEach(cloud.sharedSources) { source in
                        cloudCalendarRow(source)
                    }
                }
                NavigationLink {
                    if cloud.session != nil { CloudReceivedCalendarsView() }
                    else { CloudWorkspaceView() }
                } label: {
                    Label("cloud.home.manage", systemImage: "icloud")
                }.accessibilityIdentifier("cloud.home.manage")
            } header: { Text("cloud.home.received") }
            footer: { Text("cloud.home.selectionHint") }
        }
        .listStyle(.insetGrouped)
        .animation(.easeInOut, value: collapsedSources)
        .navigationTitle("calendars.selectTitle")
        .toolbar { toolbarContent }
        .modifier(CalendarsChangeModifier(calendars: calendarManager.calendars) { pruneCollapsed() })
    }

    private func groupHeader(_ group: (source: String, calendars: [EKCalendar])) -> some View {
        let collapsed = collapsedSources.contains(group.source)
        return Button(action: { toggleGroup(group.source) }) {
            HStack {
                Text(group.source).font(.headline)
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
        .accessibilityLabel(Text("\(group.source) ") + Text(collapsed ? "calendars.group.collapsedSuffix" : "calendars.group.expandedSuffix"))
    }

    private func calendarRow(_ cal: EKCalendar) -> some View {
        let selected = calendarManager.selectedCalendars.contains(cal.calendarIdentifier)
        let isSharedCopy = calendarManager.managedCalendarIDs.contains(cal.calendarIdentifier)
        return Button { calendarManager.toggleCalendarSelection(cal.calendarIdentifier) } label: {
            HStack {
                Circle().fill(Color(cgColor: cal.cgColor)).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cal.title).lineLimit(1)
                    if isSharedCopy { Text("calendars.sharedCopy").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
        }
        .foregroundColor(.primary)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(cal.title + " ") +
            (isSharedCopy ? Text("calendars.sharedCopy") + Text(" ") : Text("")) +
            Text(selected ? "calendars.row.selectedSuffix" : "calendars.row.unselectedSuffix"))
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !calendarManager.calendars.isEmpty || !cloud.sharedSources.isEmpty {
                Button("calendars.selectAll") { selectAll() }
                Button("calendars.clear") { clearAll() }
            }
        }
    }

    private func selectAll() {
        calendarManager.selectAllDefaultCalendars()
        cloud.selectAllSharedSourcesForDisplay()
    }
    private func clearAll() {
        calendarManager.selectedCalendars.removeAll()
        calendarManager.loadEvents()
        cloud.clearSharedSourceDisplay()
    }

    private func cloudCalendarRow(_ source: CloudSharedSource) -> some View {
        let selected = cloud.selectedSharedSourceIDs.contains(source.id)
        return Button { cloud.toggleSharedSourceDisplay(source.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "icloud").foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.ownerName + " · " + source.name)
                    Text(source.privacy.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cloud.home.source.\(source.id.uuidString)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    
    // MARK: - Group Helpers
    private func toggleGroup(_ source: String) {
        if collapsedSources.contains(source) { collapsedSources.remove(source) } else { collapsedSources.insert(source) }
    }
    private func pruneCollapsed() {
        let existing = Set(groupedCalendars.map { $0.source })
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
