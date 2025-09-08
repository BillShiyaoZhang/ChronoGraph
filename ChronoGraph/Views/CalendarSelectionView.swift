// filepath: /Users/shiyaozhang/Developer/ChronoGraph/ChronoGraph/Views/CalendarSelectionView.swift
import SwiftUI
import EventKit

struct CalendarSelectionView: View {
    @ObservedObject var calendarManager: CalendarManager

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
                Section { Text("暂无日历（可能尚未授权）").foregroundColor(.secondary) }
            } else {
                ForEach(groupedCalendars, id: \.source) { group in
                    Section(header: Text(group.source)) {
                        ForEach(group.calendars, id: \.calendarIdentifier) { cal in
                            calendarRow(cal)
                        }
                    }
                }
            }
        }
        .animation(.default, value: calendarManager.selectedCalendars)
        .navigationTitle("选择日历")
        .toolbar { toolbarContent }
    }

    private func calendarRow(_ cal: EKCalendar) -> some View {
        let selected = calendarManager.selectedCalendars.contains(cal.calendarIdentifier)
        return Button { calendarManager.toggleCalendarSelection(cal.calendarIdentifier) } label: {
            HStack {
                Circle().fill(Color(cgColor: cal.cgColor)).frame(width: 10, height: 10)
                Text(cal.title).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundColor(.accentColor) }
            }
        }
        .foregroundColor(.primary)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(cal.title + (selected ? " 已选择" : " 未选择")))
    }

    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !calendarManager.calendars.isEmpty {
                Button("全选") { selectAll() }
                Button("清空") { clearAll() }
            }
        }
    }

    private func selectAll() {
        calendarManager.selectedCalendars = Set(calendarManager.calendars.map { $0.calendarIdentifier })
        calendarManager.loadEvents()
    }
    private func clearAll() {
        calendarManager.selectedCalendars.removeAll()
        calendarManager.loadEvents()
    }
}

#Preview { CalendarSelectionView(calendarManager: CalendarManager()) }
