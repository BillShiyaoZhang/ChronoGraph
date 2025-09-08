//
//  WeeklyGridExportView.swift
//  ChronoGraph
//
//  Created by GitHub Copilot on 05/09/2025.
//

import SwiftUI
import UIKit

struct WeeklyGridExportView: View {
    let events: [CalendarEvent]
    let privacyMode: PrivacyMode
    let dateRange: CalendarManager.DateRange
    // New: prefer near-square layout for weekly exports (set via initializer)
    let preferSquare: Bool
    
    // Provide an explicit initializer to accept preferSquare (default false)
    init(
        events: [CalendarEvent],
        privacyMode: PrivacyMode,
        dateRange: CalendarManager.DateRange,
        preferSquare: Bool = false
    ) {
        self.events = events
        self.privacyMode = privacyMode
        self.dateRange = dateRange
        self.preferSquare = preferSquare
    }
    
    // Layout constants
    // Replace fixed hour height with base + dynamic override
    @State private var overrideRowHeight: CGFloat? = nil
    private let baseHourRowHeight: CGFloat = 48
    private var hourRowHeight: CGFloat { overrideRowHeight ?? baseHourRowHeight }
    private let minRowHeightForReadability: CGFloat = 28
    private let timeLabelWidth: CGFloat = 46
    private let columnSpacing: CGFloat = 1
    private let dayHeaderHeight: CGFloat = 40
    private let allDayAreaHeight: CGFloat = 34
    
    private var isoCal: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        return c
    }
    
    private var weekStartMonday: Date {
        let interval = dateRange.dateInterval
        // Use the mid-point of the selected interval to avoid boundary-week mismatches
        let mid = interval.start.addingTimeInterval(interval.duration / 2)
        return isoCal.dateInterval(of: .weekOfYear, for: mid)?.start ?? isoCal.startOfDay(for: Date())
    }
    
    private var daysMonToSun: [Date] {
        (0..<7).compactMap { isoCal.date(byAdding: .day, value: $0, to: weekStartMonday) }
    }
    
    private let hourMarks: [Int] = Array(0...24) // include 24 to draw the bottom line
    
    // Formatters
    private let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:00"
        f.locale = .current
        f.timeZone = .current
        return f
    }()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE\nM/d" // 2-line label: Mon, 9/5
        f.locale = .current
        f.timeZone = .current
        return f
    }()
    private let timeRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = .current
        f.timeZone = .current
        return f
    }()
    
    var body: some View {
        VStack(spacing: 12) {
            header
            grid
            watermark
        }
        .padding(16)
        .background(
            LinearGradient(gradient: Gradient(colors: [Color(.systemBackground), Color(.systemGray6)]), startPoint: .top, endPoint: .bottom)
        )
    }
    
    private var header: some View {
        VStack(spacing: 6) {
            Text("Weekly Schedule").font(.title).fontWeight(.bold)
            Text(weekRangeText).font(.subheadline).foregroundColor(.secondary)
        }
    }
    
    private var weekRangeText: String {
        let start = daysMonToSun.first ?? Date()
        let end = isoCal.date(byAdding: .day, value: 6, to: start) ?? start
        let f = DateFormatter()
        f.dateFormat = "M/d"
        f.locale = .current
        f.timeZone = .current
        return "\(f.string(from: start)) - \(f.string(from: end))"
    }
    
    private var grid: some View {
        // Grid: [time labels] | [7 day columns]
        HStack(spacing: 8) {
            timeLabels
            dayColumns
        }
        // Measure grid width to adjust row height for near-square layout when requested
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateRowHeightIfNeeded(gridWidth: proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        updateRowHeightIfNeeded(gridWidth: newWidth)
                    }
            }
        )
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 3)
    }
    
    // Compute row height to make grid approximately square (height ~= width)
    private func updateRowHeightIfNeeded(gridWidth: CGFloat) {
        guard preferSquare else { return }
        let headerSum = dayHeaderHeight + allDayAreaHeight
        let target = max(minRowHeightForReadability, (gridWidth - headerSum) / 24.0)
        if let current = overrideRowHeight {
            if abs(current - target) > 0.5 { overrideRowHeight = target }
        } else {
            overrideRowHeight = target
        }
    }
    
    private var timeLabels: some View {
        VStack(spacing: 0) {
            // Header spacers align with day headers
            Rectangle().fill(Color.clear).frame(height: dayHeaderHeight + allDayAreaHeight)
            
            // Hour rows
            ForEach(0..<24, id: \.self) { h in
                HStack {
                    Text(String(format: "%02d:00", h))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: timeLabelWidth-6, alignment: .trailing)
                    Rectangle().fill(Color(.systemGray5)).frame(height: 1)
                }
                .frame(height: hourRowHeight)
            }
            // Bottom boundary line
            HStack {
                Spacer(minLength: timeLabelWidth)
                Rectangle().fill(Color(.systemGray4)).frame(height: 1)
            }
        }
        .frame(width: timeLabelWidth)
    }
    
    private var dayColumns: some View {
        HStack(spacing: columnSpacing) {
            ForEach(daysMonToSun, id: \.self) { dayStart in
                singleDayColumn(dayStart)
            }
        }
    }
    
    private func singleDayColumn(_ dayStart: Date) -> some View {
        let nextDay = isoCal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let (allDay, timed) = partitionEvents(for: dayStart)
        
        return VStack(spacing: 0) {
            // Day header
            Text(dayHeaderText(dayStart))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: dayHeaderHeight)
                .background(Color(.systemGray6))
                .overlay(Rectangle().fill(Color(.systemGray5)).frame(height: 1), alignment: .bottom)
            
            // All-day area
            allDayChips(allDay)
                .frame(height: allDayAreaHeight)
                .frame(maxWidth: .infinity)
                .background(Color(.systemBackground))
                .overlay(Rectangle().fill(Color(.systemGray5)).frame(height: 1), alignment: .bottom)
            
            // Time grid + events overlay
            ZStack(alignment: .topLeading) {
                // Hour rows background with light separators
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: hourRowHeight)
                            .overlay(Rectangle().fill(Color(.systemGray6)).frame(height: 1), alignment: .bottom)
                    }
                }
                
                // Quarter-hour hairlines (optional subtle)
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        VStack(spacing: 0) {
                            Spacer().frame(height: hourRowHeight/4)
                            Rectangle().fill(Color(.systemGray6)).frame(height: 0.5)
                            Spacer().frame(height: hourRowHeight/4)
                            Rectangle().fill(Color(.systemGray6)).frame(height: 0.5)
                            Spacer().frame(height: hourRowHeight/4)
                            Rectangle().fill(Color(.systemGray6)).frame(height: 0.5)
                            Spacer().frame(height: hourRowHeight/4)
                        }
                        .frame(height: hourRowHeight)
                    }
                }
                
                // Events
                ForEach(timed, id: \.id) { e in
                    if let block = eventBlock(for: e, in: dayStart..<nextDay) {
                        block
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .overlay(Rectangle().fill(Color(.systemGray5)).frame(width: 1), alignment: .trailing)
    }
    
    private func dayHeaderText(_ d: Date) -> String {
        let day = DateFormatter()
        day.locale = .current
        day.timeZone = .current
        day.dateFormat = "EEE"
        let md = DateFormatter()
        md.locale = .current
        md.timeZone = .current
        md.dateFormat = "M/d"
        return "\(day.string(from: d))  \(md.string(from: d))"
    }
    
    private func partitionEvents(for dayStart: Date) -> ([CalendarEvent], [CalendarEvent]) {
        let nextDay = isoCal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let dayRange = dayStart..<nextDay
        let inWeek = events.filter { $0.endDate > daysMonToSun.first! && $0.startDate < (daysMonToSun.last!.addingTimeInterval(24*3600)) }
        let overlapsDay = inWeek.filter { $0.endDate > dayRange.lowerBound && $0.startDate < dayRange.upperBound }
        let allDay = overlapsDay.filter { $0.isAllDay }
        let timed = overlapsDay.filter { !$0.isAllDay }
        return (allDay, timed)
    }
    
    private func allDayChips(_ list: [CalendarEvent]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(list, id: \.id) { e in
                    let color = Color(cgColor: e.calendarColor)
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 5, height: 5)
                        Text(privacyMode == .opaque ? e.availability.localizedName : e.title)
                            .font(.caption2)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.12))
                    .cornerRadius(8)
                }
            }
            .padding(.horizontal, 6)
        }
    }
    
    private func eventBlock(for event: CalendarEvent, in dayRange: Range<Date>) -> AnyView? {
        // Clamp to the day
        let start = max(event.startDate, dayRange.lowerBound)
        let end = max(start, min(event.endDate, dayRange.upperBound))
        let minutesFromDayStart = isoCal.dateComponents([.minute], from: dayRange.lowerBound, to: start).minute ?? 0
        let durationMinutes = max(0, isoCal.dateComponents([.minute], from: start, to: end).minute ?? 0)
        if durationMinutes == 0 { return nil }
        
        let y = CGFloat(minutesFromDayStart) / 60 * hourRowHeight
        let h = max(18, CGFloat(durationMinutes) / 60 * hourRowHeight)
        let color = Color(cgColor: event.calendarColor)
        
        let content: AnyView = {
            switch privacyMode {
            case .opaque:
                return AnyView(
                    HStack(spacing: 6) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(event.availability.localizedName).font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                )
            case .partial:
                return AnyView(
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.caption).fontWeight(.semibold).lineLimit(1)
                        Text("\(timeRangeFormatter.string(from: event.startDate)) - \(timeRangeFormatter.string(from: event.endDate))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                )
            case .full:
                return AnyView(
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.caption).fontWeight(.semibold).lineLimit(1)
                        Text("\(timeRangeFormatter.string(from: event.startDate)) - \(timeRangeFormatter.string(from: event.endDate))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let location = event.location, !location.isEmpty {
                            HStack(spacing: 4) { Image(systemName: "location.fill").font(.caption2); Text(location).font(.caption2).lineLimit(1) }
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                )
            }
        }()
        
        return AnyView(
            VStack { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: h)
                .background(color.opacity(0.18))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(color, lineWidth: 1))
                .cornerRadius(6)
                .offset(y: y)
                .padding(.horizontal, 2)
        )
    }
    
    private var watermark: some View {
        HStack { Spacer(); VStack(spacing: 2) { Image(systemName: "clock.badge.checkmark").font(.caption).foregroundColor(.secondary); Text("Generated by ChronoGraph").font(.caption2).foregroundColor(.secondary) }
            .padding(.horizontal, 10).padding(.vertical, 6).background(Color(.systemGray6)).cornerRadius(8) }
    }
}

#Preview {
    WeeklyGridExportView(
        events: [
            CalendarEvent(
                id: "1",
                title: "Team Sync",
                startDate: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!,
                endDate: Calendar.current.date(bySettingHour: 11, minute: 0, second: 0, of: Date())!,
                calendar: "Work",
                calendarColor: UIColor.systemBlue.cgColor
            ),
            CalendarEvent(
                id: "2",
                title: "Lunch",
                startDate: Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!,
                endDate: Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: Date())!,
                calendar: "Personal",
                calendarColor: UIColor.systemGreen.cgColor
            ),
            CalendarEvent(
                id: "3",
                title: "Offsite",
                startDate: Calendar.current.startOfDay(for: Date()),
                endDate: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!,
                calendar: "Work",
                calendarColor: UIColor.systemOrange.cgColor,
                isAllDay: true
            )
        ],
        privacyMode: .partial,
        dateRange: .last7Days,
        preferSquare: true
    )
}
