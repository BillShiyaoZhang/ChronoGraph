// CalendarVisualizationView.swift
// ChronoGraph
// Multi‑day visualization (export & in‑app)

import SwiftUI

// NOTE: The data model (CalendarEvent, PrivacyMode) lives in Models/CalendarEvent.swift.
// This file previously duplicated those types causing an ambiguity compile error.
// Duplicates removed.

struct CalendarVisualizationView: View {
    let events: [CalendarEvent]
    let privacyMode: PrivacyMode
    let dateRange: CalendarManager.DateRange
    let forExport: Bool
    
    init(events: [CalendarEvent], privacyMode: PrivacyMode, dateRange: CalendarManager.DateRange, forExport: Bool = false) {
        self.events = events
        self.privacyMode = privacyMode
        self.dateRange = dateRange
        self.forExport = forExport
    }
    
    // MARK: Derived date list
    private var days: [Date] {
        let interval = dateRange.dateInterval
        var list: [Date] = []
        var cursor = Calendar.current.startOfDay(for: interval.start)
        while cursor < interval.end {
            list.append(cursor)
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return list
    }
    
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE  M/d"; return f
    }()
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(days, id: \.self) { day in daySection(day) }
            if forExport { watermark }
        }
        .padding(forExport ? 0 : 16)
        .background(forExport ? Color(.systemBackground) : Color.clear)
    }
    
    // MARK: - Sections
    private func daySection(_ day: Date) -> some View {
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let dayEvents = events.filter { $0.endDate > day && $0.startDate < nextDay }
        let allDay = dayEvents.filter { $0.isAllDay }
        let timed = dayEvents.filter { !$0.isAllDay }.sorted { a, b in a.startDate < b.startDate }
        return VStack(alignment: .leading, spacing: 12) {
            Text(dayFormatter.string(from: day))
                .font(.headline)
                .padding(.horizontal, 4)
            if allDay.isEmpty && timed.isEmpty {
                Text("⚠️ 无事件")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                if !allDay.isEmpty { allDayRow(allDay) }
                VStack(spacing: 8) { ForEach(timed, id: \.id) { timedRow($0) } }
            }
        }
    }
    
    // MARK: - Rows
    private func allDayRow(_ list: [CalendarEvent]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(list, id: \.id) { e in pill(e) }
            }.padding(.horizontal, 4)
        }.frame(height: 34)
    }
    
    private func timedRow(_ e: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color(cgColor: e.calendarColor))
                .frame(width: 4)
                .cornerRadius(2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(privacyTitle(e))
                        .font(.subheadline).fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    Text(timeRangeText(e))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if privacyMode == .full, let loc = e.location, !loc.isEmpty {
                    HStack(spacing: 4) { Image(systemName: "location"); Text(loc) }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if privacyMode != .opaque { // 避免不透明模式下重复显示状态
                    availabilityBadge(e)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
    
    private func pill(_ e: CalendarEvent) -> some View {
        let color = Color(cgColor: e.calendarColor)
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(privacyTitle(e)).font(.caption2).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.15))
        .foregroundColor(.primary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    // MARK: - Helpers
    private func privacyTitle(_ e: CalendarEvent) -> String { privacyMode == .opaque ? e.availability.localizedName : e.title }
    private func timeRangeText(_ e: CalendarEvent) -> String { e.isAllDay ? "全天" : "\(timeFormatter.string(from: e.startDate)) - \(timeFormatter.string(from: e.endDate))" }
    private func availabilityBadge(_ e: CalendarEvent) -> some View {
        HStack(spacing: 6) {
            Circle().fill(e.availability.color).frame(width: 7, height: 7)
            Text(e.availability.localizedName).font(.caption2).foregroundColor(e.availability.color)
            Spacer()
        }
    }
    private var watermark: some View {
        HStack { Spacer(); VStack(spacing: 2) { Image(systemName: "clock.badge.checkmark").font(.caption).foregroundColor(.secondary); Text("Generated by ChronoGraph").font(.caption2).foregroundColor(.secondary) }
            .padding(.horizontal, 10).padding(.vertical, 6).background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 8)) }
            .padding(.top, 12)
    }
}

#Preview {
    let start = Calendar.current.startOfDay(for: Date())
    let events: [CalendarEvent] = [
        CalendarEvent(id: "1", title: "Design Sync", startDate: start.addingTimeInterval(9*3600), endDate: start.addingTimeInterval(10*3600), calendar: "Work", availability: .busy),
        CalendarEvent(id: "2", title: "Lunch", startDate: start.addingTimeInterval(12*3600), endDate: start.addingTimeInterval(13*3600), calendar: "Personal", availability: .free),
        CalendarEvent(id: "3", title: "All Day Offsite", startDate: start, endDate: start.addingTimeInterval(86400), calendar: "Corp", isAllDay: true, availability: .unavailable)
    ]
    return ScrollView { CalendarVisualizationView(events: events, privacyMode: .partial, dateRange: .today) }
}
