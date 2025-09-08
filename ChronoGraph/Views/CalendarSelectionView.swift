// filepath: /Users/shiyaozhang/Developer/ChronoGraph/ChronoGraph/Views/CalendarSelectionView.swift
import SwiftUI
import EventKit

struct CalendarSelectionView: View {
    @ObservedObject var calendarManager: CalendarManager

    var body: some View {
        List {
            if calendarManager.calendars.isEmpty {
                Section { Text("暂无日历（可能尚未授权）").foregroundColor(.secondary) }
            } else {
                Section("日历") {
                    ForEach(calendarManager.calendars, id: \.calendarIdentifier) { cal in
                        let selected = calendarManager.selectedCalendars.contains(cal.calendarIdentifier)
                        Button { calendarManager.toggleCalendarSelection(cal.calendarIdentifier) } label: {
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
                }
                Section {
                    HStack {
                        Button("全选") { selectAll() }
                        Spacer()
                        Button("清空") { clearAll() }
                    }
                }
            }
        }
        .animation(.default, value: calendarManager.selectedCalendars)
        .navigationTitle("选择日历")
        .toolbar { toolbarContent }
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
