import SwiftUI

struct InAppEventListView: View {
    let events: [CalendarEvent]
    let privacyMode: PrivacyMode
    let dateRange: CalendarManager.DateRange
    let collapseEmptyDays: Bool // 折叠空白日期（仍显示标题，不显示占位行）
    
    @State private var selectedEvent: CalendarEvent? = nil
    
    private let dayHeaderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE – M/d"
        return f
    }()
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    
    // 全量日期分组（包含空白）
    private var grouped: [(day: Date, items: [CalendarEvent])] {
        let cal = Calendar.current
        let interval = dateRange.dateInterval
        let startDay = cal.startOfDay(for: interval.start)
        let endDay = cal.startOfDay(for: interval.end)
        var days: [Date] = []
        var cursor = startDay
        while cursor < endDay {
            days.append(cursor)
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let dict = Dictionary(grouping: events) { cal.startOfDay(for: $0.startDate) }
        return days.map { day in
            let items = (dict[day] ?? []).sorted { a, b in a.startDate < b.startDate }
            return (day, items)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(grouped, id: \.day) { day, items in
                Section(header: dayHeader(day)) {
                    if items.isEmpty {
                        if !collapseEmptyDays { emptyRow() }
                    } else {
                        ForEach(items) { e in
                            Button { selectedEvent = e } label: { row(e) }
                                .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedEvent) { ev in
            EventDetailView(event: ev, privacyMode: privacyMode)
        }
    }
    
    private func dayHeader(_ day: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        return HStack(spacing: 10) {
            if isToday {
                Text("今天")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundColor(.accentColor)
            }
            Text(dayHeaderFormatter.string(from: day))
                .font(.headline)
                .fontWeight(isToday ? .semibold : .regular)
                .foregroundColor(isToday ? .accentColor : .primary)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(
            ZStack(alignment: .leading) {
                Color(.systemGroupedBackground)
                if isToday { Color.accentColor.opacity(0.06) }
                if isToday { Rectangle().fill(Color.accentColor).frame(width: 3).opacity(0.85) }
            }
        )
    }
    
    private func emptyRow() -> some View {
        HStack {
            Text("无事件")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }
    
    private func row(_ e: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(Color(cgColor: e.calendarColor))
                .frame(width: 4)
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(privacyTitle(for: e))
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(timeText(e))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if privacyMode == .full, let loc = e.location, !loc.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "location")
                        Text(loc)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
                if privacyMode != .opaque { availabilityBadge(e) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(Color(.systemBackground))
    }
    
    private func availabilityBadge(_ e: CalendarEvent) -> some View {
        HStack(spacing: 6) {
            Circle().fill(e.availability.color).frame(width: 8, height: 8)
            Text(e.availability.localizedName)
                .font(.caption2)
                .foregroundColor(e.availability.color)
            Spacer()
        }
    }
    
    private func privacyTitle(for e: CalendarEvent) -> String {
        switch privacyMode {
        case .opaque: return e.availability.localizedName
        case .partial, .full: return e.title
        }
    }
    
    private func timeText(_ e: CalendarEvent) -> String {
        if e.isAllDay { return "all‑day" }
        return "\(timeFormatter.string(from: e.startDate)) - \(timeFormatter.string(from: e.endDate))"
    }
}

struct EventDetailView: View {
    let event: CalendarEvent
    let privacyMode: PrivacyMode
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd HH:mm"; return f
    }()
    var body: some View {
        NavigationStack {
            List {
                Section("时间") {
                    if event.isAllDay { Text("全天") } else {
                        Text("开始: " + timeFormatter.string(from: event.startDate))
                        Text("结束: " + timeFormatter.string(from: event.endDate))
                    }
                }
                if privacyMode != .opaque {
                    Section("详情") {
                        if let loc = event.location, !loc.isEmpty { Label(loc, systemImage: "location") }
                        if let notes = event.notes, !notes.isEmpty { Text(notes) }
                    }
                }
                Section("日历") {
                    HStack { Circle().fill(Color(cgColor: event.calendarColor)).frame(width: 10, height: 10); Text(event.calendar) }
                }
                Section("忙碌状态") { Label(event.availability.localizedName, systemImage: "circle.fill").foregroundStyle(event.availability.color) }
            }
            .navigationTitle(privacyMode == .opaque ? event.availability.localizedName : event.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    InAppEventListView(
        events: [],
        privacyMode: .full,
        dateRange: .today,
        collapseEmptyDays: false
    )
}
