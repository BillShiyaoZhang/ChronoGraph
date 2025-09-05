//
//  CalendarVisualizationView.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import SwiftUI
import UIKit

struct CalendarVisualizationView: View {
    let events: [CalendarEvent]
    let privacyMode: PrivacyMode
    let dateRange: CalendarManager.DateRange
    let forExport: Bool
    
    // 按类型拆分事件
    private var allDayEvents: [CalendarEvent] { events.filter { $0.isAllDay } }
    private var timedEvents: [CalendarEvent] { events.filter { !$0.isAllDay } }
    
    init(
        events: [CalendarEvent],
        privacyMode: PrivacyMode,
        dateRange: CalendarManager.DateRange,
        forExport: Bool = false
    ) {
        self.events = events
        self.privacyMode = privacyMode
        self.dateRange = dateRange
        self.forExport = forExport
    }
    
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = .current
        f.locale = .current
        return f
    }()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 EEEE"
        f.timeZone = .current
        f.locale = .current
        return f
    }()
    
    private let hourHeight: CGFloat = 60
    private let startHour: Int = 6
    private let endHour: Int = 23
    
    // 取出区间内的天
    private var daysInRange: [Date] {
        let cal = Calendar.current
        let interval = dateRange.dateInterval
        var day = cal.startOfDay(for: interval.start)
        let end = interval.end.addingTimeInterval(-1)
        var days: [Date] = []
        while day <= end {
            days.append(day)
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return days
    }
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color(.systemBackground), Color(.systemGray6)]),
                startPoint: .top, endPoint: .bottom
            ).ignoresSafeArea()
            
            Group {
                if forExport { mainContent.fixedSize(horizontal: false, vertical: true) } else { ScrollView { mainContent } }
            }
        }
    }
    
    private var mainContent: some View {
        VStack(spacing: 20) {
            headerSection
            
            // 多天渲染
            VStack(spacing: 16) {
                ForEach(daysInRange, id: \.self) { dayStart in
                    daySection(for: dayStart)
                }
            }
            
            watermarkView
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("我的日程").font(.largeTitle).fontWeight(.bold)
            Text(dateRangeText).font(.subheadline).foregroundColor(.secondary)
        }
        .padding(.top, 10)
    }
    
    private var dateRangeText: String {
        let interval = dateRange.dateInterval
        let cal = Calendar.current
        let endAdjusted = interval.end.addingTimeInterval(-1)
        if cal.isDate(interval.start, inSameDayAs: endAdjusted) {
            return dayFormatter.string(from: interval.start)
        } else {
            return "\(dayFormatter.string(from: interval.start)) - \(dayFormatter.string(from: endAdjusted))"
        }
    }
    
    // 单天 section（含全天 chips + 时间轴）
    private func daySection(for dayStart: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dayFormatter.string(from: dayStart))
                .font(.headline)
                .foregroundColor(.primary)
            
            let (allDay, timed) = eventsForDay(dayStart)
            if !allDay.isEmpty { allDayChips(allDay) }
            
            dayTimeline(dayStart: dayStart, timedEvents: timed)
                .background(Color(.systemBackground))
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 3)
        }
    }
    
    private func eventsForDay(_ dayStart: Date) -> ([CalendarEvent], [CalendarEvent]) {
        let cal = Calendar.current
        let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart)!
        func overlapsDay(_ e: CalendarEvent) -> Bool {
            // e [start,end) overlaps [dayStart,nextDay)
            return e.endDate > dayStart && e.startDate < nextDay
        }
        let all = events.filter(overlapsDay)
        let allDay = all.filter { $0.isAllDay }
        let timed = all.filter { !$0.isAllDay }
        return (allDay, timed)
    }
    
    private func allDayChips(_ list: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sun.max.fill").foregroundColor(.orange)
                Text("全天").font(.subheadline).foregroundColor(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(list) { event in
                        let color = Color(cgColor: event.calendarColor)
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(privacyMode == .opaque ? "繁忙" : event.title)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(color.opacity(0.12))
                        .cornerRadius(12)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }
    
    private func dayTimeline(dayStart: Date, timedEvents: [CalendarEvent]) -> some View {
        VStack(spacing: 0) {
            ForEach(startHour..<endHour, id: \.self) { hour in
                timeSlotView(for: hour)
                    .frame(height: hourHeight)
            }
        }
        .padding(.vertical, 16)
        .overlay(
            GeometryReader { _ in
                ForEach(timedEvents) { e in
                    dayEventBlock(e, dayStart: dayStart)
                }
            }
        )
    }
    
    private func timeSlotView(for hour: Int) -> some View {
        HStack {
            VStack { Text("\(hour):00").font(.caption).foregroundColor(.secondary); Spacer() }
                .frame(width: 50)
            Rectangle().fill(Color(.systemGray5)).frame(height: 1)
                .overlay(
                    HStack { ForEach(0..<4, id: \.self) { q in if q>0 { Rectangle().fill(Color(.systemGray6)).frame(width: 1, height: 8) }; Spacer() } }
                )
            Spacer()
        }
    }
    
    private func dayEventBlock(_ event: CalendarEvent, dayStart: Date) -> some View {
        // 可见窗口 [startHour, endHour)
        let cal = Calendar.current
        let visibleStart = cal.date(byAdding: .hour, value: startHour, to: dayStart)!
        let visibleEnd = cal.date(byAdding: .hour, value: endHour, to: dayStart)!
        let start = max(event.startDate, visibleStart)
        let end = max(start, min(event.endDate, visibleEnd))
        
        let minutesFromVisibleStart = cal.dateComponents([.minute], from: visibleStart, to: start).minute ?? 0
        let durationMinutes = max(0, cal.dateComponents([.minute], from: start, to: end).minute ?? 0)
        let y = CGFloat(minutesFromVisibleStart) / 60.0 * hourHeight
        let h = max(30, CGFloat(durationMinutes) / 60.0 * hourHeight)
        
        let border = eventBorderColor(event)
        let background = eventBackgroundColor(event)
        
        return HStack(spacing: 0) {
            Rectangle().frame(width: 50).foregroundColor(.clear)
            VStack(alignment: .leading, spacing: 4) {
                // Use actual event times in label while layout remains clamped to visible window
                eventContentView(event, displayedStart: event.startDate, displayedEnd: event.endDate)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: h)
            .background(background)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(border, lineWidth: 2))
        }
        .offset(y: y)
    }
    
    @ViewBuilder
    private func eventContentView(_ event: CalendarEvent, displayedStart: Date, displayedEnd: Date) -> some View {
        let accent = eventBorderColor(event)
        switch privacyMode {
        case .opaque:
            HStack { Circle().fill(accent).frame(width: 8, height: 8); Text("繁忙").font(.caption).foregroundColor(.secondary); Spacer() }
        case .partial:
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(.subheadline, design: .rounded)).fontWeight(.medium).lineLimit(2)
                Text("\(timeFormatter.string(from: displayedStart)) - \(timeFormatter.string(from: displayedEnd))").font(.caption).foregroundColor(.secondary)
            }
        case .full:
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.system(.subheadline, design: .rounded)).fontWeight(.medium).lineLimit(1)
                Text("\(timeFormatter.string(from: displayedStart)) - \(timeFormatter.string(from: displayedEnd))").font(.caption).foregroundColor(.secondary)
                if let location = event.location, !location.isEmpty {
                    HStack(spacing: 4) { Image(systemName: "location.fill").font(.caption2); Text(location).font(.caption2) }
                        .foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }
    
    private func eventBackgroundColor(_ event: CalendarEvent) -> Color {
        let base = Color(cgColor: event.calendarColor)
        let opacity: Double = switch privacyMode { case .opaque: 0.28; case .partial: 0.2; case .full: 0.16 }
        return base.opacity(opacity)
    }
    private func eventBorderColor(_ event: CalendarEvent) -> Color { Color(cgColor: event.calendarColor) }
    
    private var watermarkView: some View {
        HStack { Spacer(); VStack(spacing: 4) { Image(systemName: "clock.badge.checkmark").font(.caption).foregroundColor(.secondary); Text("由 ChronoGraph 创建").font(.caption2).foregroundColor(.secondary) }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Color(.systemGray6)).cornerRadius(8) }
        .padding(.bottom, 10)
    }
}

#Preview {
    CalendarVisualizationView(
        events: [
            CalendarEvent(
                id: "1",
                title: "团队会议",
                startDate: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!,
                endDate: Calendar.current.date(bySettingHour: 11, minute: 30, second: 0, of: Date())!,
                calendar: "工作",
                calendarColor: UIColor.systemBlue.cgColor
            ),
            CalendarEvent(
                id: "2",
                title: "午餐约会",
                startDate: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(bySettingHour: 12, minute: 30, second: 0, of: Date())!)!,
                endDate: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!)!,
                calendar: "个人",
                calendarColor: UIColor.systemGreen.cgColor
            ),
            CalendarEvent(
                id: "3",
                title: "节假日",
                startDate: Calendar.current.startOfDay(for: Date()),
                endDate: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!,
                calendar: "系统",
                calendarColor: UIColor.systemOrange.cgColor,
                isAllDay: true
            )
        ],
        privacyMode: .partial,
        dateRange: .thisWeek
    )
}
