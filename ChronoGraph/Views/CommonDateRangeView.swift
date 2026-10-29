import SwiftUI

/// A local selection control. Applying a range never publishes calendar changes.
struct DateRangeMenu: View {
    let selection: SharedCalendarRange
    let onSelect: (SharedCalendarRange) -> Void
    let onCustom: () -> Void
    var identifierPrefix = "dateRange"
    var showsTitle = false
    var includesCustomRange = true

    var body: some View {
        Menu {
            ForEach([1, 3, 7, 14], id: \.self) { days in
                let range = SharedCalendarRange.rolling(pastDays: 0, futureDays: days - 1, timeZoneIdentifier: selection.timeZoneIdentifier)
                Button { onSelect(range) } label: {
                    HStack {
                        Text(presetKey(days))
                        if selection == range { Image(systemName: "checkmark") }
                    }
                }
                .accessibilityIdentifier("\(identifierPrefix).\(presetIdentifier(days))")
                .accessibilityAddTraits(selection == range ? .isSelected : [])
            }
            if includesCustomRange {
                Divider()
                Button(action: onCustom) { Label("dateRange.custom", systemImage: usesCustomRange ? "checkmark" : "calendar.badge.plus") }
                    .accessibilityIdentifier("\(identifierPrefix).custom")
                    .accessibilityAddTraits(usesCustomRange ? .isSelected : [])
            }
        } label: {
            if showsTitle {
                Label("accessibility.dateRangePicker", systemImage: "calendar")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            } else { Image(systemName: "calendar") }
        }
        .accessibilityLabel(Text("accessibility.dateRangePicker"))
        .accessibilityIdentifier(identifierPrefix)
    }

    private var usesCustomRange: Bool {
        guard case .rolling(let past, let future, _) = selection else { return true }
        return past != 0 || ![0, 2, 6, 13].contains(future)
    }

    private func presetKey(_ days: Int) -> LocalizedStringKey {
        switch days {
        case 1: return "dateRange.today"
        case 3: return "dateRange.last3Days"
        case 7: return "dateRange.last7Days"
        default: return "dateRange.last14Days"
        }
    }

    private func presetIdentifier(_ days: Int) -> String {
        switch days {
        case 1: return "today"
        case 3: return "last3Days"
        case 7: return "last7Days"
        default: return "last14Days"
        }
    }
}

struct DateRangePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onApply: (SharedCalendarRange) -> Void
    private let timeZoneIdentifier: String
    @State private var usesFixedRange: Bool
    @State private var pastDays: Int
    @State private var futureDays: Int
    @State private var fixedStart: Date
    @State private var fixedEnd: Date
    @State private var operationError: String?

    init(range: SharedCalendarRange, onApply: @escaping (SharedCalendarRange) -> Void) {
        self.onApply = onApply
        timeZoneIdentifier = range.timeZoneIdentifier
        let calendar = calendarInTimeZone(range.timeZoneIdentifier)
        let interval = try? range.dateInterval()
        let today = calendar.startOfDay(for: Date())
        switch range {
        case .rolling(let past, let future, _):
            _usesFixedRange = State(initialValue: false)
            _pastDays = State(initialValue: past)
            _futureDays = State(initialValue: future)
        case .fixed:
            _usesFixedRange = State(initialValue: true)
            _pastDays = State(initialValue: 0)
            _futureDays = State(initialValue: 6)
        }
        _fixedStart = State(initialValue: interval?.start ?? today)
        _fixedEnd = State(initialValue: calendar.date(byAdding: .day, value: -1, to: interval?.end ?? today) ?? today)
    }

    private var canApply: Bool { usesFixedRange ? fixedEnd >= fixedStart : pastDays >= 0 && futureDays >= 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("sharing.range.mode", selection: $usesFixedRange) {
                        Text("sharing.range.rolling").tag(false)
                        Text("sharing.range.fixed").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("sharing.range.mode")
                    if usesFixedRange {
                        DatePicker("date.start", selection: $fixedStart, displayedComponents: .date)
                            .accessibilityIdentifier("sharing.range.start")
                            .onChange(of: fixedStart) { _, start in if fixedEnd < start { fixedEnd = start } }
                        DatePicker("date.end", selection: $fixedEnd, in: fixedStart..., displayedComponents: .date)
                            .accessibilityIdentifier("sharing.range.end")
                    } else {
                        dayCountField("sharing.range.pastDays", value: $pastDays, identifier: "sharing.range.pastDays")
                        dayCountField("sharing.range.futureDays", value: $futureDays, identifier: "sharing.range.futureDays")
                    }
                } footer: {
                    Text(usesFixedRange ? LocalizedStringKey("dateRange.fixed.help") : LocalizedStringKey("dateRange.rolling.help"))
                    Text("dateRange.limit.help")
                }
                Section { LabeledContent("sharing.range.timeZone", value: timeZoneIdentifier) }
            }
            .environment(\.timeZone, TimeZone(identifier: timeZoneIdentifier) ?? .current)
            .navigationTitle("dateRange.custom")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.accessibilityIdentifier("sharing.range.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.apply") { apply() }.disabled(!canApply).accessibilityIdentifier("sharing.range.save")
                }
            }
            .sharingErrorAlert($operationError)
        }
    }

    private func dayCountField(_ title: LocalizedStringKey, value: Binding<Int>, identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90)
                .accessibilityIdentifier(identifier)
        }
    }

    private func apply() {
        do {
            let calendar = calendarInTimeZone(timeZoneIdentifier)
            let range: SharedCalendarRange
            if usesFixedRange {
                guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: fixedEnd)) else { throw SharedCalendarModelError.invalidRange }
                range = .fixed(start: calendar.startOfDay(for: fixedStart), endExclusive: end, timeZoneIdentifier: timeZoneIdentifier)
            } else {
                range = .rolling(pastDays: pastDays, futureDays: futureDays, timeZoneIdentifier: timeZoneIdentifier)
            }
            _ = try range.dateInterval()
            onApply(range)
            dismiss()
        } catch { operationError = error.localizedDescription }
    }
}
