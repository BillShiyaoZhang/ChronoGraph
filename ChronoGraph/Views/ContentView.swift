//  ContentView.swift
//  ChronoGraph
//
//  Main content: authorization, date range, privacy mode, calendar selection, event list, export

import SwiftUI
import EventKit
import SafariServices

struct ContentView: View {
    // MARK: - State / Managers
    @StateObject private var calendarManager: CalendarManager
    @StateObject private var exportManager = ImageExportManager()
    @State private var showingCalendarPicker = false
    @State private var showingPrivacySheet = false
    @State private var showWeeklySquareToggle = false
    @State private var preferSquareWeekly = true
    @State private var showingFullScreenExportPreview = false
    @State private var exportType: ExportType? = nil
    @State private var isRequestingAuth = false
    @State private var showingSettingsSheet = false
    @State private var sampleToggleA = true
    @State private var sampleToggleB = false
    @State private var showingPrivacyPolicy = false // Sheet for SafariViewController
    // Persist only collapse preference here; other prefs centralized in CalendarManager
    @AppStorage("pref.collapseEmptyDays") private var collapseEmptyDays: Bool = false
    // Capture current content width for identical export layout
    @State private var contentWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize // ensure exported image uses same dynamic type
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var languageManager: LanguageManager
    @EnvironmentObject private var sharedCalendarManager: SharedCalendarManager
    @State private var homeMode: HomeMode = .personal
    @AppStorage("sharing.selectedProfileID") private var selectedSharedProfileID = ""
    @State private var showingSharedRangeSheet = false
    @State private var sharedExportEvents: [SharedEventPreview] = []
    @State private var sharedExportVersion: String?
    @State private var operationError: String?
    @State private var customDateProfileID: UUID?
    @State private var customTimeZoneIdentifier = TimeZone.current.identifier

    private enum HomeMode { case personal, shared }

    init() {
        #if DEBUG
        let loadsCalendars = !ProcessInfo.processInfo.arguments.contains("-sharing-home-fixtures")
        #else
        let loadsCalendars = true
        #endif
        _calendarManager = StateObject(wrappedValue: CalendarManager(loadsCalendars: loadsCalendars))
    }

    // Date popover state
    // @State private var showingDatePopover = false
    @State private var customStart = Date()
    @State private var customEnd = Calendar.current.date(byAdding: .day, value: 7, to: Date())!
    @State private var showingCustomDateSheet = false

    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-" }
    private var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-" }
    private var defaultSharingSourceIDs: Set<String> {
        calendarManager.selectedCalendars.subtracting(calendarManager.managedCalendarIDs)
    }
    private var sharedProfiles: [SharedCalendarProfile] { sharedCalendarManager.profiles.filter { !$0.pendingDeletion } }
    private var sharedProfile: SharedCalendarProfile? {
        sharedProfiles.first { $0.id.uuidString == selectedSharedProfileID } ?? sharedProfiles.first
    }
    private var sharedProfileVersion: String {
        guard let profile = sharedProfile else { return "empty" }
        return "\(profile.id)-\(profile.revision)-\(profile.lastUpdated?.timeIntervalSince1970 ?? 0)"
    }
    private var canShowSchedule: Bool {
        sharedCalendarManager.isUsingPreviewFixtures || calendarManager.isAuthorizedForRead || isRequestingAuth
    }

    // Language-aware privacy policy URL (from localized resources)
    private var privacyPolicyURL: URL {
        func localizedString(for key: String, languageCode: String) -> String? {
            // Map to supported lproj names
            let lproj: String
            if languageCode.lowercased().hasPrefix("zh") { lproj = "zh-Hans" }
            else if languageCode.lowercased().hasPrefix("en") { lproj = "en" }
            else { lproj = languageCode }
            if let path = Bundle.main.path(forResource: lproj, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                let value = NSLocalizedString(key, tableName: "Localizable", bundle: bundle, value: "", comment: "")
                return value.isEmpty ? nil : value
            }
            return nil
        }
        let code = languageManager.effectiveLanguageCode
        let zhString = localizedString(for: "privacy.policy.url", languageCode: "zh-Hans")
        let primaryString = localizedString(for: "privacy.policy.url", languageCode: code) ?? zhString
        if let s = primaryString, let url = URL(string: s) { return url }
        // Final hardcoded fallback to Chinese URL
        return URL(string: "https://github.com/BillShiyaoZhang/ChronoGraph/blob/main/隐私政策.md")!
    }

    enum ExportType { case list }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if canShowSchedule {
                    if homeMode == .personal { contentLayer }
                    else {
                        SharedScheduleHomeView(profile: sharedProfile, defaultSourceIDs: defaultSharingSourceIDs,
                            defaultPrivacyMode: calendarManager.privacyMode, collapseEmptyDays: collapseEmptyDays) { version, events in
                            sharedExportEvents = events ?? []
                            sharedExportVersion = events == nil ? nil : version
                        }
                    }
                } else if calendarManager.isDeniedOrRestricted {
                    deniedView
                } else {
                    requestAccessView
                }
            }
            .navigationTitle(homeMode == .personal ? Text("home.personal") : (sharedProfile.map { Text($0.name) } ?? Text("home.shared")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettingsSheet = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(Text("settings.title"))
                        .accessibilityIdentifier("home.settings")
                }
            }
            .sheet(isPresented: $showingSettingsSheet) { settingsSheet }
            .sheet(isPresented: $exportManager.showingShareSheet) { ExportShareSheet(activityItems: exportItems()) }
            .sheet(isPresented: $showingSharedRangeSheet) {
                if let profile = sharedProfile { NavigationStack { SharedCalendarRangeEditorView(profile: profile) } }
            }
            .sheet(isPresented: $showingCustomDateSheet) {
                CustomDateRangeSheet(start: $customStart, end: $customEnd,
                    onCancel: { showingCustomDateSheet = false }, onApply: applyCustomDateRange)
                    .environment(\.timeZone, TimeZone(identifier: customTimeZoneIdentifier) ?? .current)
                    .presentationDetents([.medium, .large])
            }
            .sharingErrorAlert($operationError)
            .task { calendarManager.refreshAuthorizationStatus() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { calendarManager.refreshAuthorizationStatus() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: DispatchQueue.main)) { _ in
                calendarManager.refreshAuthorizationStatus()
            }
        }
    }

    private var contentLayer: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 20) {
                InAppEventListView(
                    events: calendarManager.events,
                    privacyMode: calendarManager.privacyMode,
                    dateRange: calendarManager.selectedDateRange,
                    collapseEmptyDays: collapseEmptyDays
                )
                .id(calendarManager.selectedDateRange)
            }
            .padding(.top, 4)
            // Width capture (only once stable > 0)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentWidthPreferenceKey.self, value: proxy.size.width)
            })
        }
        .onPreferenceChange(ContentWidthPreferenceKey.self) { w in
            if w > 0 { contentWidth = w }
        }
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if canShowSchedule {
            ToolbarItemGroup(placement: .bottomBar) {
                viewSelectionToolbarItem
                privacyModeToolbarItem
                dateSelectionToolbarItem
                Spacer()
                shareToolbarItem
            }
        }
    }

    private var viewSelectionToolbarItem: some View {
        Menu {
            Button { homeMode = .personal } label: {
                Label("home.personal", systemImage: homeMode == .personal ? "checkmark" : "person")
            }
            .accessibilityIdentifier("home.mode.personal")
            Button { homeMode = .shared } label: {
                Label("home.shared", systemImage: homeMode == .shared ? "checkmark" : "person.2")
            }
            .accessibilityIdentifier("home.mode.shared")
            if !sharedProfiles.isEmpty {
                Section("home.chooseSharedCalendar") {
                    ForEach(sharedProfiles) { profile in
                        Button {
                            selectedSharedProfileID = profile.id.uuidString
                            homeMode = .shared
                        } label: {
                            if homeMode == .shared && sharedProfile?.id == profile.id { Label(profile.name, systemImage: "checkmark") }
                            else { Text(profile.name) }
                        }
                        .accessibilityIdentifier("home.shared.profile.\(profile.name)")
                    }
                }
            }
        } label: { Image(systemName: "square.stack") }
        .accessibilityLabel(Text("home.mode"))
        .accessibilityValue(homeMode == .personal ? Text("home.personal") : (sharedProfile.map { Text($0.name) } ?? Text("home.shared")))
        .accessibilityIdentifier("home.mode")
    }

    private var shareToolbarItem: some View {
        Button { triggerExport(.list) } label: { Image(systemName: "square.and.arrow.up") }
            .accessibilityLabel(Text("export.share"))
            .disabled(homeMode == .shared && (sharedProfile == nil || sharedExportVersion != sharedProfileVersion || sharedCalendarManager.isBusy))
    }

    private var dateSelectionToolbarItem: some View {
        Menu {
            Section("section.dateRange") {
                ForEach(CalendarManager.DateRange.presets, id: \.self) { range in
                    Button { applyDatePreset(range) } label: {
                        HStack {
                            Text(range.localizedKey)
                            if isSelectedDatePreset(range) { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("home.\(homeMode == .shared ? "shared" : "personal").range.\(range.identifier)")
                    .accessibilityAddTraits(isSelectedDatePreset(range) ? .isSelected : [])
                }
                Divider()
                Button { openCustomDateRange() } label: {
                    Label("dateRange.custom", systemImage: "calendar.badge.plus")
                }
                .accessibilityIdentifier(homeMode == .shared ? "home.shared.range.custom" : "home.personal.range.custom")
                if homeMode == .shared, let profile = sharedProfile {
                    Divider()
                    SharedRangeSummary(range: profile.range)
                    Button { showingSharedRangeSheet = true } label: {
                        Label("sharing.range.title", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier("home.shared.range.edit")
                }
            }
        } label: {
            Image(systemName: "calendar")
        }
        .accessibilityLabel(Text("accessibility.dateRangePicker"))
        .accessibilityIdentifier(homeMode == .shared ? "home.shared.range" : "home.personal.range")
        .disabled(homeMode == .shared && (sharedProfile == nil || sharedCalendarManager.isBusy))
    }

    private func sharedPreset(_ range: CalendarManager.DateRange, zone: String) -> SharedCalendarRange {
        let future: Int
        switch range {
        case .today: future = 0
        case .last3Days: future = 2
        case .last7Days: future = 6
        case .last14Days: future = 13
        case .custom(let start, let end): return .fixed(start: start, endExclusive: end, timeZoneIdentifier: zone)
        }
        return .rolling(pastDays: 0, futureDays: future, timeZoneIdentifier: zone)
    }

    private func isSelectedDatePreset(_ range: CalendarManager.DateRange) -> Bool {
        if homeMode == .personal { return range == calendarManager.selectedDateRange }
        guard let profile = sharedProfile else { return false }
        return profile.range == sharedPreset(range, zone: profile.range.timeZoneIdentifier)
    }

    private func applyDatePreset(_ range: CalendarManager.DateRange) {
        if homeMode == .personal { calendarManager.updateDateRange(range); return }
        guard let profile = sharedProfile else { return }
        let newRange = sharedPreset(range, zone: profile.range.timeZoneIdentifier)
        Task { await updateSharedProfile(profile) { try await sharedCalendarManager.updateRange(profileID: profile.id, range: newRange) } }
    }

    private func openCustomDateRange() {
        let interval: DateInterval
        if homeMode == .shared, let profile = sharedProfile, let sharedInterval = try? profile.range.dateInterval() {
            customDateProfileID = profile.id
            customTimeZoneIdentifier = profile.range.timeZoneIdentifier
            interval = sharedInterval
        } else {
            customDateProfileID = nil
            customTimeZoneIdentifier = TimeZone.current.identifier
            interval = calendarManager.selectedDateRange.dateInterval
        }
        let calendar = calendarInTimeZone(customTimeZoneIdentifier)
        customStart = calendar.startOfDay(for: interval.start)
        customEnd = calendar.startOfDay(for: interval.end.addingTimeInterval(-1))
        showingCustomDateSheet = true
    }

    private func applyCustomDateRange() {
        let calendar = calendarInTimeZone(customTimeZoneIdentifier)
        var start = calendar.startOfDay(for: customStart)
        var endDay = calendar.startOfDay(for: customEnd)
        if start > endDay { swap(&start, &endDay) }
        guard let end = calendar.date(byAdding: .day, value: 1, to: endDay) else { return }
        showingCustomDateSheet = false
        if let id = customDateProfileID, let profile = sharedCalendarManager.profiles.first(where: { $0.id == id }) {
            let range = SharedCalendarRange.fixed(start: start, endExclusive: end, timeZoneIdentifier: customTimeZoneIdentifier)
            Task { await updateSharedProfile(profile) { try await sharedCalendarManager.updateRange(profileID: id, range: range) } }
        } else if customDateProfileID == nil {
            calendarManager.updateDateRange(.custom(start: start, endExclusive: end))
        }
    }

    private func updateSharedProfile(_ profile: SharedCalendarProfile, action: () async throws -> Void) async {
        do { try await action() }
        catch {
            let latest = sharedCalendarManager.profiles.first { $0.id == profile.id }
            let saved = latest != nil && latest?.revision != profile.revision
            operationError = (saved ? NSLocalizedString("sharing.save.savedNotPublished", comment: "") + "\n\n" : "") + error.localizedDescription
        }
    }

    @ViewBuilder
    private var datePopoverContent: some View {
        EmptyView()
    }

    // MARK: - Popover presenter with iOS version fallback
    private struct DatePopoverPresenter<Popover: View>: ViewModifier {
        @Binding var isPresented: Bool
        @ViewBuilder var popoverContent: () -> Popover

        func body(content: Content) -> some View { content }
    }

    private var privacyModeToolbarItem: some View {
        Menu {
            Section("section.privacyMode") {
                ForEach(PrivacyMode.allCases, id: \.self) { (mode: PrivacyMode) in
                    Button {
                        if homeMode == .personal { calendarManager.updatePrivacyMode(mode) }
                        else if let profile = sharedProfile {
                            Task { await updateSharedProfile(profile) { try await sharedCalendarManager.updatePrivacyMode(profileID: profile.id, privacyMode: mode) } }
                        }
                    } label: {
                        HStack { Text(mode.localizedKey); if mode == displayedPrivacyMode { Image(systemName: "checkmark") } }
                    }
                    .accessibilityIdentifier("home.\(homeMode == .shared ? "shared" : "personal").privacy.\(mode.rawValue)")
                    .accessibilityAddTraits(mode == displayedPrivacyMode ? .isSelected : [])
                }
            }
        } label: {
            Image(systemName: "eye")
//            Text(calendarManager.privacyMode.localizedKey)
        }
        .accessibilityLabel(Text("accessibility.filter"))
        .accessibilityIdentifier(homeMode == .shared ? "home.shared.privacy" : "home.personal.privacy")
        .disabled(homeMode == .shared && (sharedProfile == nil || sharedCalendarManager.isBusy))
    }

    private var displayedPrivacyMode: PrivacyMode {
        homeMode == .personal ? calendarManager.privacyMode : (sharedProfile?.privacyMode ?? .partial)
    }
    
    // MARK: - Authorization States
        private var requestAccessView: some View {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "calendar.badge.plus").font(.system(size: 54)).symbolRenderingMode(.hierarchical).foregroundColor(.accentColor)
                Text("auth.required").font(.title2).fontWeight(.semibold)
                Text("auth.hint").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button {
                    isRequestingAuth = true
                    Task { await calendarManager.requestCalendarAccess(); isRequestingAuth = false }
                } label: {
                    Text(isRequestingAuth ? "auth.requesting" : "auth.request")
                        .font(.headline)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)], startPoint: .leading, endPoint: .trailing)))
                        .foregroundColor(.white)
                        .shadow(color: Color.accentColor.opacity(0.4), radius: 12, y: 6)
                }
                .disabled(isRequestingAuth)
                Spacer()
            }
            .padding(.bottom, 40)
            .padding(.horizontal, 24)
        }

        private var deniedView: some View {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "lock.slash").font(.system(size: 52)).foregroundColor(.secondary)
                Text("auth.denied").font(.title2).fontWeight(.semibold)
                Text("auth.denied.hint").font(.subheadline).foregroundColor(.secondary)
                Button("auth.refresh") { calendarManager.refreshAuthorizationStatus() }
                    .padding(.top, 4)
                Spacer()
            }
            .padding(.bottom, 40)
            .padding(.horizontal, 24)
        }

    // MARK: - Settings Sheet
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { LanguageSettingsView() } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("settings.language")
                            Spacer()
                        }
                    }
                    NavigationLink {
                        if homeMode == .shared, let profile = sharedProfile { SharedCalendarSourcesEditorView(profile: profile) }
                        else { CalendarSelectionView(calendarManager: calendarManager) }
                    } label: {
                        HStack {
                            Text("settings.calendars")
                            Spacer()
                            if !calendarManager.isAuthorizedForRead { Text("status.unauthorized").foregroundColor(.secondary).font(.caption) }
                        }
                    }
                    .accessibilityLabel(Text("accessibility.calendarSelection"))
                    .accessibilityIdentifier(homeMode == .shared ? "home.shared.sources" : "home.personal.sources")
                    .disabled(homeMode == .shared && sharedProfile == nil)

                    NavigationLink {
                        SharedCalendarsView(defaultSourceIDs: defaultSharingSourceIDs,
                            defaultPrivacyMode: calendarManager.privacyMode)
                    } label: {
                        Label("sharing.title", systemImage: "person.2.crop.square.stack")
                    }

                    Toggle("settings.collapseEmptyDays", isOn: $collapseEmptyDays)
                    
                    Text("settings.collapseEmptyDays.help")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("section.appInfo") {
                    HStack { Text("app.version"); Spacer(); Text(appVersion).foregroundColor(.secondary) }
                    HStack { Text("app.build"); Spacer(); Text(appBuild).foregroundColor(.secondary) }
                    Button("settings.privacyPolicy") { showingPrivacyPolicy = true }
                }
//                Section("section.support") {
//                    Button("settings.feedback") { }
//                    Button("settings.rate") { }
//                }
            }
            .navigationTitle(Text("settings.title"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("common.done") { showingSettingsSheet = false }.accessibilityIdentifier("home.settings.done") } }
            .sheet(isPresented: $showingPrivacyPolicy) { SafariView(url: privacyPolicyURL) }
        }
    }

    // MARK: - Export Logic (modified for WYSIWYG long image)
    private func triggerExport(_ type: ExportType) { exportType = type; Task { await generateExport(type) } }

    @MainActor private func generateExport(_ type: ExportType) async {
        // Screen width (foreground scene or legacy main) — exported image must match this exactly
        func screenWidth() -> CGFloat {
            #if os(iOS)
            if #available(iOS 17.0, *) {
                if let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }) {
                    return scene.screen.bounds.width
                }
            }
            return UIScreen.main.bounds.width
            #else
            return contentWidth
            #endif
        }
        let width = screenWidth()
        switch type {
        case .list:
            let list: AnyView
            if homeMode == .shared, let profile = sharedProfile, let interval = try? profile.range.dateInterval(),
               sharedExportVersion == sharedProfileVersion {
                list = AnyView(InAppEventListView(sharedEvents: sharedExportEvents, dateInterval: interval,
                    timeZone: TimeZone(identifier: profile.range.timeZoneIdentifier) ?? .current,
                    collapseEmptyDays: collapseEmptyDays, onSelect: { _ in }))
            } else if homeMode == .personal {
                list = AnyView(InAppEventListView(events: calendarManager.events, privacyMode: calendarManager.privacyMode,
                    dateRange: calendarManager.selectedDateRange, collapseEmptyDays: collapseEmptyDays))
            } else { return }
            let identicalList = AnyView(
                list
                .padding(.top, 4)
                .frame(width: width)
                .background(Color(.systemBackground))
                .environment(\.dynamicTypeSize, dynamicTypeSize)
            )
            await exportManager.generateImage(from: identicalList, targetWidth: width, colorScheme: colorScheme)
        }
        exportManager.shareImage()
    }

    private func exportItems() -> [Any] {
        var items: [Any] = []
        if let img = exportManager.generatedImage {
            // Provide a UIActivityItemSource for better type recognition & previews
            items.append(ExportedImageItemSource(image: img))
        }
        return items
    }
    // Helper selection management retained
    private func selectAllCalendars() { calendarManager.selectAllDefaultCalendars() }
    private func clearAllCalendars() { calendarManager.selectedCalendars.removeAll(); calendarManager.loadEvents() }
}

// MARK: - Share Sheet Wrapper
struct ExportShareSheet: UIViewControllerRepresentable { // Renamed to avoid conflict
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

// SafariView wrapper for SFSafariViewController
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: config)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) { }
}

// PreferenceKey for capturing content width
private struct ContentWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// System default style custom date range sheet
private struct CustomDateRangeSheet: View {
    @Binding var start: Date
    @Binding var end: Date
    var onCancel: () -> Void
    var onApply: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("date.start", selection: $start, displayedComponents: .date)
                    DatePicker("date.end", selection: $end, in: start..., displayedComponents: .date)
                }
                if start > end {
                    Section {
                        Label("error.invalidRange", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(Text("dateRange.custom"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("common.apply", action: onApply).disabled(start > end) }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(LanguageManager())
        .environmentObject(SharedCalendarManager())
}
