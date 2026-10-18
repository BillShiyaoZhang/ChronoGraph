import SwiftUI

struct SharedCalendarEditorView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    @Environment(\.dismiss) private var dismiss
    private let existingProfile: SharedCalendarProfile?
    @State private var draftID: UUID
    @State private var name: String
    @State private var sourceIDs: Set<String>
    @State private var targetSourceID: String
    @State private var privacyMode: PrivacyMode
    @State private var usesFixedRange: Bool
    @State private var pastDays: Int
    @State private var futureDays: Int
    @State private var fixedStart: Date
    @State private var fixedEnd: Date
    @State private var timeZoneIdentifier: String
    @State private var confirmsICloud = false
    @State private var operationError: String?
    @State private var showingCreatedGuide = false

    init(profile: SharedCalendarProfile?, defaultSourceIDs: Set<String>, defaultPrivacyMode: PrivacyMode) {
        existingProfile = profile
        _draftID = State(initialValue: profile?.id ?? UUID())
        _name = State(initialValue: profile?.name ?? "")
        _sourceIDs = State(initialValue: profile?.sourceCalendarIDs ?? defaultSourceIDs)
        _targetSourceID = State(initialValue: profile?.targetSourceID ?? "")
        _privacyMode = State(initialValue: profile?.privacyMode ?? defaultPrivacyMode)
        let range = profile?.range ?? .rolling()
        _timeZoneIdentifier = State(initialValue: range.timeZoneIdentifier)
        let calendar = calendarInTimeZone(range.timeZoneIdentifier)
        switch range {
        case .rolling(let past, let future, _):
            _usesFixedRange = State(initialValue: false)
            _pastDays = State(initialValue: past)
            _futureDays = State(initialValue: future)
            _fixedStart = State(initialValue: calendar.startOfDay(for: Date()))
            _fixedEnd = State(initialValue: calendar.date(byAdding: .day, value: 90, to: calendar.startOfDay(for: Date())) ?? Date())
        case .fixed(let start, let end, _):
            _usesFixedRange = State(initialValue: true)
            _pastDays = State(initialValue: 7)
            _futureDays = State(initialValue: 90)
            _fixedStart = State(initialValue: start)
            _fixedEnd = State(initialValue: calendar.date(byAdding: .day, value: -1, to: end) ?? start)
        }
    }

    private var availableCalendars: [SharedCalendarOption] { manager.calendars.filter { !$0.isManaged } }
    private var selectedAccount: SharedCalendarAccount? { manager.accounts.first { $0.id == targetSourceID } }
    private var visibilityDescriptionKey: LocalizedStringKey {
        switch privacyMode {
        case .opaque: return "privacy.opaque.desc"
        case .partial: return "privacy.partial.desc"
        case .full: return "privacy.full.desc"
        }
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !targetSourceID.isEmpty &&
        (existingProfile != nil || (confirmsICloud && selectedAccount != nil)) &&
        (!usesFixedRange || fixedEnd >= fixedStart) && !manager.isBusy
    }

    var body: some View {
        Form {
            Section {
                TextField("sharing.name", text: $name)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("sharing.name")
                if existingProfile == nil {
                    Picker("sharing.account", selection: $targetSourceID) {
                        Text("sharing.account.choose").tag("")
                        ForEach(manager.accounts) { account in Text(account.title).tag(account.id) }
                    }
                    .accessibilityIdentifier("sharing.account")
                    .onChange(of: targetSourceID) { _, _ in confirmsICloud = false }
                    if let account = selectedAccount {
                        if !account.calendarTitles.isEmpty {
                            Text(account.calendarTitles.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("sharing.account.confirm", isOn: $confirmsICloud)
                            .accessibilityIdentifier("sharing.account.confirm")
                    }
                    if manager.accounts.isEmpty {
                        Label("sharing.account.empty", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } else {
                    HStack {
                        Text("sharing.account")
                        Spacer()
                        if let account = selectedAccount { Text(account.title).foregroundStyle(.secondary) }
                        else { Text("sharing.account.unavailable").foregroundStyle(.secondary) }
                    }
                }
            } footer: { Text(existingProfile == nil ? LocalizedStringKey("sharing.account.help") : LocalizedStringKey("sharing.account.fixed")) }

            Section {
                Picker("sharing.defaultVisibility", selection: $privacyMode) {
                    ForEach(PrivacyMode.allCases, id: \.rawValue) { mode in Text(mode.localizedKey).tag(mode) }
                }
                Text(visibilityDescriptionKey).font(.caption).foregroundStyle(.secondary)
            } footer: { Text("sharing.defaultVisibility.help") }

            Section("sharing.range.title") {
                Picker("sharing.range.mode", selection: $usesFixedRange) {
                    Text("sharing.range.rolling").tag(false)
                    Text("sharing.range.fixed").tag(true)
                }
                if usesFixedRange {
                    DatePicker("date.start", selection: $fixedStart, displayedComponents: .date)
                        .onChange(of: fixedStart) { _, start in if fixedEnd < start { fixedEnd = start } }
                    DatePicker("date.end", selection: $fixedEnd, in: fixedStart..., displayedComponents: .date)
                } else {
                    HStack { Text("sharing.range.pastDays"); Spacer(); TextField("7", value: $pastDays, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90) }
                    HStack { Text("sharing.range.futureDays"); Spacer(); TextField("90", value: $futureDays, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90) }
                }
                LabeledContent("sharing.range.timeZone", value: timeZoneIdentifier)
            }
            .environment(\.timeZone, TimeZone(identifier: timeZoneIdentifier) ?? .current)

            Section {
                if availableCalendars.isEmpty { Text("calendars.empty").foregroundStyle(.secondary) }
                ForEach(availableCalendars) { calendar in
                    Button { toggle(calendar.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(calendar.title).foregroundStyle(.primary)
                                Text(calendar.sourceTitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if sourceIDs.contains(calendar.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(sourceIDs.contains(calendar.id) ? .isSelected : [])
                }
                let unavailableIDs = sourceIDs.subtracting(Set(availableCalendars.map(\.id)))
                if !unavailableIDs.isEmpty {
                    Label("sharing.sources.unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("sharing.sources.removeUnavailable") { sourceIDs.subtract(unavailableIDs) }
                }
            } header: {
                HStack {
                    Text("sharing.sources")
                    Spacer()
                    Button("calendars.selectAll") { sourceIDs = Set(availableCalendars.map(\.id)) }.textCase(nil)
                    Button("calendars.clear") { sourceIDs.removeAll() }.textCase(nil)
                }
            } footer: { Text("sharing.sources.help") }

            Section { Text("sharing.target.help").font(.footnote).foregroundStyle(.secondary) }
        }
        .disabled(manager.isBusy)
        .navigationTitle(Text(existingProfile == nil ? LocalizedStringKey("sharing.create") : LocalizedStringKey("sharing.edit")))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() }.disabled(manager.isBusy) }
            ToolbarItem(placement: .confirmationAction) {
                Button("common.save") { Task { await save() } }
                    .disabled(!canSave)
                    .accessibilityIdentifier("sharing.save")
            }
        }
        .interactiveDismissDisabled(manager.isBusy)
        .sheet(isPresented: $showingCreatedGuide, onDismiss: { dismiss() }) {
            NavigationStack { SharedCalendarGuideView(calendarName: EventKitCalendarStore.namePrefix + name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        .sharingErrorAlert($operationError)
    }

    private func toggle(_ id: String) {
        if sourceIDs.contains(id) { sourceIDs.remove(id) } else { sourceIDs.insert(id) }
    }

    private func save() async {
        do {
            let calendar = calendarInTimeZone(timeZoneIdentifier)
            let range: SharedCalendarRange
            if usesFixedRange {
                guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: fixedEnd)) else { return }
                range = .fixed(start: calendar.startOfDay(for: fixedStart), endExclusive: end, timeZoneIdentifier: timeZoneIdentifier)
            } else {
                range = .rolling(pastDays: pastDays, futureDays: futureDays, timeZoneIdentifier: timeZoneIdentifier)
            }
            _ = try range.dateInterval()
            var profile = existingProfile ?? SharedCalendarProfile(id: draftID, name: name, sourceCalendarIDs: sourceIDs, targetSourceID: targetSourceID)
            profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.sourceCalendarIDs = sourceIDs
            profile.privacyMode = privacyMode
            profile.range = range
            if existingProfile == nil {
                try await manager.create(profile)
                showingCreatedGuide = true
            } else {
                try await manager.update(profile)
                dismiss()
            }
        } catch {
            let persistedProfile = manager.profiles.first { $0.id == draftID }
            if (existingProfile == nil && persistedProfile != nil) ||
                (existingProfile != nil && persistedProfile?.revision != existingProfile?.revision) {
                // Creation may already have committed the destination. Repair that
                // persisted configuration rather than creating another calendar,
                // or resubmitting an editor whose configuration version is stale.
                dismiss()
            } else {
                operationError = error.localizedDescription
            }
        }
    }
}
