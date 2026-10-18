import SwiftUI

struct SharedCalendarRangeEditorView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    @Environment(\.dismiss) private var dismiss
    private let profileID: UUID
    private let timeZoneIdentifier: String
    @State private var usesFixedRange: Bool
    @State private var pastDays: Int
    @State private var futureDays: Int
    @State private var fixedStart: Date
    @State private var fixedEnd: Date
    @State private var isSaving = false
    @State private var operationError: String?
    @State private var savedBeforeFailure = false

    init(profile: SharedCalendarProfile) {
        profileID = profile.id
        timeZoneIdentifier = profile.range.timeZoneIdentifier
        let calendar = calendarInTimeZone(profile.range.timeZoneIdentifier)
        switch profile.range {
        case .rolling(let past, let future, _):
            _usesFixedRange = State(initialValue: false)
            _pastDays = State(initialValue: past)
            _futureDays = State(initialValue: future)
            _fixedStart = State(initialValue: calendar.startOfDay(for: Date()))
            _fixedEnd = State(initialValue: calendar.date(byAdding: .day, value: future, to: calendar.startOfDay(for: Date())) ?? Date())
        case .fixed(let start, let end, _):
            _usesFixedRange = State(initialValue: true)
            _pastDays = State(initialValue: 7)
            _futureDays = State(initialValue: 90)
            _fixedStart = State(initialValue: start)
            _fixedEnd = State(initialValue: calendar.date(byAdding: .day, value: -1, to: end) ?? start)
        }
    }

    private var isBusy: Bool { isSaving || manager.isBusy }
    private var canSave: Bool {
        guard !isBusy, manager.profiles.contains(where: { $0.id == profileID && !$0.pendingDeletion }) else { return false }
        return usesFixedRange ? fixedEnd >= fixedStart : pastDays >= 0 && futureDays >= 0
    }

    var body: some View {
        Form {
            Section {
                Picker("sharing.range.mode", selection: $usesFixedRange) {
                    Text("sharing.range.rolling").tag(false)
                    Text("sharing.range.fixed").tag(true)
                }
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
            } footer: { Text("sharing.range.currentCalendar") }
            Section {
                LabeledContent("sharing.range.timeZone", value: timeZoneIdentifier)
            }
        }
        .environment(\.timeZone, TimeZone(identifier: timeZoneIdentifier) ?? .current)
        .disabled(isBusy)
        .navigationTitle("sharing.range.title")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("common.cancel") { dismiss() }
                    .disabled(isBusy)
                    .accessibilityIdentifier("sharing.range.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.save") { Task { await save() } }
                    .disabled(!canSave)
                    .accessibilityIdentifier("sharing.range.save")
            }
        }
        .interactiveDismissDisabled(isBusy)
        .alert(Text(savedBeforeFailure ? LocalizedStringKey("sharing.save.savedTitle") : LocalizedStringKey("sharing.error.title")), isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("common.done") { if savedBeforeFailure { dismiss() } }
        } message: {
            if savedBeforeFailure {
                Text("sharing.save.savedNotPublished") + Text("\n\n") + Text(operationError ?? "")
            } else { Text(operationError ?? "") }
        }
    }

    private func dayCountField(_ title: LocalizedStringKey, value: Binding<Int>, identifier: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .accessibilityIdentifier(identifier)
        }
    }

    private func save() async {
        guard !isBusy else { return }
        isSaving = true
        defer { isSaving = false }
        var submittedRevision: Int?
        var submittedRange: SharedCalendarRange?
        do {
            let calendar = calendarInTimeZone(timeZoneIdentifier)
            let range: SharedCalendarRange
            if usesFixedRange {
                guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: fixedEnd)) else {
                    throw SharedCalendarModelError.invalidRange
                }
                range = .fixed(start: calendar.startOfDay(for: fixedStart), endExclusive: end, timeZoneIdentifier: timeZoneIdentifier)
            } else {
                range = .rolling(pastDays: pastDays, futureDays: futureDays, timeZoneIdentifier: timeZoneIdentifier)
            }
            _ = try range.dateInterval()
            guard let profile = manager.profiles.first(where: { $0.id == profileID }) else {
                throw SharedCalendarError.staleConfiguration
            }
            submittedRevision = profile.revision
            submittedRange = range
            try await manager.updateRange(profileID: profileID, range: range)
            dismiss()
        } catch {
            let latest = manager.profiles.first { $0.id == profileID }
            savedBeforeFailure = submittedRevision != nil && latest != nil && latest?.revision != submittedRevision && latest?.range == submittedRange
            operationError = error.localizedDescription
        }
    }
}
