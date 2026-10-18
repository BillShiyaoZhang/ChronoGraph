import SwiftUI

/// The renderer receives only fields that are allowed to appear in the list.
struct EventListDisplayItem: Identifiable {
    let id: String
    let eventIndex: Int
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let calendarColor: CGColor
    let isAllDay: Bool
    let availability: CalendarEvent.Availability
    let showsAvailability: Bool

    init(event: CalendarEvent, privacyMode: PrivacyMode, eventIndex: Int = 0) {
        id = event.id
        self.eventIndex = eventIndex
        title = privacyMode == .opaque ? event.availability.localizedName : event.title
        startDate = event.startDate
        endDate = event.endDate
        location = privacyMode == .full ? event.location : nil
        calendarColor = event.calendarColor
        isAllDay = event.isAllDay
        availability = event.availability
        showsAvailability = privacyMode != .opaque
    }

    init?(sharedEvent: SharedEventPreview, eventIndex: Int = 0) {
        guard sharedEvent.visibility != .excluded, let published = sharedEvent.published else { return nil }
        id = sharedEvent.id
        self.eventIndex = eventIndex
        title = published.title
        startDate = published.startDate
        endDate = published.endDate
        location = sharedEvent.visibility == .full ? published.location : nil
        calendarColor = UIColor.systemBlue.cgColor
        isAllDay = published.isAllDay
        availability = published.availability
        showsAvailability = sharedEvent.visibility != .opaque
    }
}

struct EventListDisplayDay: Identifiable {
    let date: Date
    let items: [EventListDisplayItem]
    var id: Date { date }

    static func grouped(items: [EventListDisplayItem], interval: DateInterval, calendar: Calendar) -> [Self] {
        let itemsByDay = Dictionary(grouping: items) { calendar.startOfDay(for: $0.startDate) }
        var days: [Self] = []
        var cursor = calendar.startOfDay(for: interval.start)
        while cursor < interval.end {
            days.append(Self(date: cursor, items: (itemsByDay[cursor] ?? []).sorted { $0.startDate < $1.startDate }))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return days
    }
}

struct InAppEventListView: View {
    private let personalEvents: [CalendarEvent]
    private let sharedEvents: [SharedEventPreview]
    private let privacyMode: PrivacyMode
    private let dateInterval: DateInterval
    private let timeZone: TimeZone
    private let onSelectShared: ((SharedEventPreview) -> Void)?
    let collapseEmptyDays: Bool

    @State private var selectedEvent: CalendarEvent? = nil

    init(events: [CalendarEvent], privacyMode: PrivacyMode, dateRange: CalendarManager.DateRange, collapseEmptyDays: Bool) {
        personalEvents = events
        sharedEvents = []
        self.privacyMode = privacyMode
        dateInterval = dateRange.dateInterval
        timeZone = .current
        onSelectShared = nil
        self.collapseEmptyDays = collapseEmptyDays
    }

    init(sharedEvents: [SharedEventPreview], dateInterval: DateInterval, timeZone: TimeZone,
         collapseEmptyDays: Bool, onSelect: @escaping (SharedEventPreview) -> Void) {
        personalEvents = []
        self.sharedEvents = sharedEvents
        privacyMode = .partial
        self.dateInterval = dateInterval
        self.timeZone = timeZone
        onSelectShared = onSelect
        self.collapseEmptyDays = collapseEmptyDays
    }

    private var isShared: Bool { onSelectShared != nil }
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar
    }

    private var grouped: [EventListDisplayDay] {
        let items = isShared
            ? sharedEvents.enumerated().compactMap { EventListDisplayItem(sharedEvent: $0.element, eventIndex: $0.offset) }
            : personalEvents.enumerated().map { EventListDisplayItem(event: $0.element, privacyMode: privacyMode, eventIndex: $0.offset) }
        return EventListDisplayDay.grouped(items: items, interval: dateInterval, calendar: calendar)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(grouped) { day in
                Section(header: dayHeader(day.date)) {
                    if day.items.isEmpty {
                        if !collapseEmptyDays { emptyRow() }
                    } else {
                        ForEach(day.items) { item in
                            eventButton(item)
                            Divider()
                        }
                    }
                }
            }
        }
        .environment(\.timeZone, timeZone)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: collapseEmptyDays)
        .sheet(item: $selectedEvent) { ev in
            EventDetailView(event: ev, privacyMode: privacyMode)
        }
    }

    @ViewBuilder
    private func eventButton(_ item: EventListDisplayItem) -> some View {
        if let onSelectShared {
            let event = sharedEvents[item.eventIndex]
            Button { onSelectShared(event) } label: { row(item) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.shared.event.\(item.id)")
        } else {
            let event = personalEvents[item.eventIndex]
            Button { selectedEvent = event } label: { row(item) }
                .buttonStyle(.plain)
        }
    }
    
    private func dayHeader(_ day: Date) -> some View {
        let isToday = calendar.isDateInToday(day)
        return HStack(spacing: 10) {
            if isToday {
                Text("today")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    .foregroundColor(.accentColor)
            }
            Group {
                Text(day, format: .dateTime.weekday(.wide)) + Text(" – ") + Text(day, format: .dateTime.month(.defaultDigits).day(.defaultDigits))
            }
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
            Text("empty.noEvents")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }
    
    private func row(_ e: EventListDisplayItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(Color(cgColor: e.calendarColor))
                .frame(width: 4)
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(e.title)
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .accessibilityIdentifier(isShared ? "home.shared.event.title" : "event.title.\(e.id)")
                    Spacer()
                    if e.isAllDay {
                        Text("event.allDay").font(.caption).foregroundColor(.secondary)
                    } else {
                        HStack(spacing: 2) {
                            Text(e.startDate, format: .dateTime.hour().minute())
                            Text("-")
                            Text(e.endDate, format: .dateTime.hour().minute())
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                if let loc = e.location, !loc.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "location")
                        Text(loc)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
                if e.showsAvailability { availabilityBadge(e) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(Color(.systemBackground))
    }
    
    private func availabilityBadge(_ e: EventListDisplayItem) -> some View {
        HStack(spacing: 6) {
            Circle().fill(e.availability.color).frame(width: 8, height: 8)
            Text(e.availability.localizedName)
                .font(.caption2)
                .foregroundColor(e.availability.color)
            Spacer()
        }
    }
}

struct EventDetailView: View {
    let event: CalendarEvent
    let privacyMode: PrivacyMode
    var body: some View {
        NavigationStack {
            List {
                Section("detail.time") {
                    if event.isAllDay { Text("detail.allDay") } else {
                        HStack { Text("detail.start"); Spacer(); Text(event.startDate, format: .dateTime.year().month().day().hour().minute()) }
                        HStack { Text("detail.end"); Spacer(); Text(event.endDate, format: .dateTime.year().month().day().hour().minute()) }
                    }
                }
                if privacyMode == .full {
                    Section("detail.info") {
                        if let loc = event.location, !loc.isEmpty { Label(loc, systemImage: "location") }
                        if let notes = event.notes, !notes.isEmpty { Text(notes) }
                    }
                }
                if privacyMode != .opaque {
                    Section("detail.calendar") {
                        HStack { Circle().fill(Color(cgColor: event.calendarColor)).frame(width: 10, height: 10); Text(event.calendar) }
                    }
                }
                Section("detail.availability") { Label(event.availability.localizedName, systemImage: "circle.fill").foregroundStyle(event.availability.color) }
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
