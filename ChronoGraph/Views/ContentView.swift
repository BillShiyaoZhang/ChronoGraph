import SwiftUI
import EventKit
import SafariServices

struct ContentView: View {
    @StateObject private var calendarManager: CalendarManager
    @StateObject private var exportManager = ImageExportManager()
    @EnvironmentObject private var languageManager: LanguageManager
    @EnvironmentObject private var sharedCalendarManager: SharedCalendarManager
    @EnvironmentObject private var workspace: SharingWorkspace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("pref.collapseEmptyDays") private var collapseEmptyDays = false
    @AppStorage("sharing.selectedProfileID") private var selectedProfileID = ""
    @State private var sharedMode = false
    @State private var showingSettings = false
    @State private var showingDate = false
    @State private var showingPrivacyPolicy = false
    @State private var isRequestingAuth = false
    @State private var showingCalendarPicker = false
    @State private var editorPresentation: SharedEditorPresentation?
    @State private var subscriptionProfile: SharedCalendarProfile?
    @State private var pendingSubscription: SharedCalendarProfile?
    @State private var pendingNewCalendar = false
    @State private var showingActivity = false
    @State private var activityItems: [Any] = []
    @State private var pendingActivity: [Any]?
    @State private var imageContext: ImageContext?
    @State private var imageUnsharedCount = 0
    @State private var browsedEvents: [SharedEventPreview] = []

    private struct ImageContext: Identifiable {
        let id = UUID()
        let profileID: UUID?
        let browse: ShareBrowseSettings?
        let events: [CalendarEvent]
        let range: SharedCalendarRange
        let privacy: PrivacyMode
    }

    private struct SharedEditorPresentation: Identifiable {
        let id = UUID()
        let profile: SharedCalendarProfile?
        let browse: ShareBrowseSettings
        let defaultSourceIDs: Set<String>
        let reviewsBrowseOnOpen: Bool
    }

    init() {
        #if DEBUG
        let loads = !ProcessInfo.processInfo.arguments.contains("-sharing-home-fixtures")
        #else
        let loads = true
        #endif
        _calendarManager = StateObject(wrappedValue: CalendarManager(loadsCalendars: loads))
    }

    private var profiles: [SharedCalendarProfile] { sharedCalendarManager.profiles.filter { !$0.pendingDeletion } }
    private var profile: SharedCalendarProfile? { profiles.first { $0.id.uuidString == selectedProfileID } ?? profiles.first }
    private var browse: ShareBrowseSettings? {
        profile.map { workspace.browse(profileID: $0.id, defaultProfile: $0) }
    }
    private var personalRange: SharedCalendarRange { workspace.personalRange ?? legacyPersonalRange }
    private var currentRange: SharedCalendarRange { sharedMode ? browse?.range ?? personalRange : personalRange }
    private var currentSources: Set<String> { sharedMode ? browse?.sourceCalendarIDs ?? [] : calendarManager.selectedCalendars.subtracting(calendarManager.managedCalendarIDs) }
    private var canShowSchedule: Bool { sharedCalendarManager.isUsingPreviewFixtures || calendarManager.isAuthorizedForRead || isRequestingAuth }
    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-" }
    private var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-" }
    private var legacyPersonalRange: SharedCalendarRange {
        let zone = TimeZone.current.identifier
        switch calendarManager.selectedDateRange {
        case .today: return .rolling(pastDays: 0, futureDays: 0, timeZoneIdentifier: zone)
        case .last3Days: return .rolling(pastDays: 0, futureDays: 2, timeZoneIdentifier: zone)
        case .last7Days: return .rolling(pastDays: 0, futureDays: 6, timeZoneIdentifier: zone)
        case .last14Days: return .rolling(pastDays: 0, futureDays: 13, timeZoneIdentifier: zone)
        case .custom(let start, let end): return .fixed(start: start, endExclusive: end, timeZoneIdentifier: zone)
        }
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


    var body: some View {
        NavigationStack {
            Group {
                if canShowSchedule {
                    if sharedMode {
                        SharedScheduleHomeView(profile: profile, browse: browse, collapseEmptyDays: collapseEmptyDays,
                            onCreate: { beginEditor(nil) },
                            onEdit: { if let profile { beginEditor(profile, reviewBrowseChanges: true) } },
                            onPreviewChange: { browsedEvents = $0 })
                    } else { personalContent }
                } else if calendarManager.isDeniedOrRestricted { deniedView }
                else { requestAccessView }
            }
            .navigationTitle(sharedMode ? profile.map { Text($0.name) } ?? Text("home.shared") : Text("home.personal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canShowSchedule {
                    ToolbarItemGroup(placement: .bottomBar) {
                        visibilityMenu
                        DateRangeMenu(selection: currentRange, onSelect: setViewingRange,
                            onCustom: { showingDate = true }, identifierPrefix: sharedMode ? "home.shared.range" : "home.personal.range")
                        Spacer()
                        modeMenu
                        shareMenu
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(Text("settings.title")).accessibilityIdentifier("home.settings")
                }
            }
            .sheet(isPresented: $showingSettings) { settingsSheet }
            .sheet(isPresented: $showingDate) {
                DateRangePickerSheet(range: currentRange, onApply: setViewingRange)
            }
            .sheet(item: $imageContext, onDismiss: finishPresentation) { context in
                NavigationStack {
                    CalendarImagePreview(isShared: context.profileID != nil, unsharedEventCount: imageUnsharedCount,
                        generate: { scope in await generateImage(scope, context: context) },
                        onShare: { image in stageShare([ExportedImageItemSource(image: image)]) })
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("common.cancel") { imageContext = nil }.accessibilityIdentifier("share.image.close")
                        } }
                }
            }
            .sheet(isPresented: $showingCalendarPicker, onDismiss: finishPresentation) {
                NavigationStack {
                    PersonalCalendarSharingPicker(profiles: profiles,
                        onSelect: { pendingSubscription = $0; showingCalendarPicker = false },
                        onCreate: { pendingNewCalendar = true; showingCalendarPicker = false })
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("common.cancel") { showingCalendarPicker = false }
                        } }
                }
            }
            .sheet(item: $subscriptionProfile, onDismiss: finishPresentation) { selected in
                NavigationStack {
                    SubscriptionSharingView(profile: sharedCalendarManager.profiles.first { $0.id == selected.id } ?? selected,
                        hasDraft: workspace.draft(profileID: selected.id) != nil || workspace.eventDrafts.values.contains { $0.profileID == selected.id },
                        onShare: { stageShare([$0]) })
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("common.cancel") { subscriptionProfile = nil }.accessibilityIdentifier("share.calendar.close")
                        } }
                }
            }
            .sheet(item: $editorPresentation, onDismiss: finishPresentation) { presentation in
                NavigationStack {
                    SharedCalendarEditorView(profile: presentation.profile, defaultSourceIDs: presentation.defaultSourceIDs,
                        defaultPrivacyMode: .opaque, initialBrowse: presentation.browse,
                        reviewsBrowseOnOpen: presentation.reviewsBrowseOnOpen,
                        onCreated: { pendingSubscription = $0; editorPresentation = nil })
                }
            }
            .sheet(isPresented: $showingActivity) { ExportShareSheet(activityItems: activityItems) }
            .task {
                if workspace.personalRange == nil { workspace.personalRange = legacyPersonalRange }
                calendarManager.refreshAuthorizationStatus()
                applyPersonalRange()
            }
            .onChange(of: workspace.personalRange) { _, _ in applyPersonalRange() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { calendarManager.refreshAuthorizationStatus(); applyPersonalRange() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: DispatchQueue.main)) { _ in
                calendarManager.refreshAuthorizationStatus(); applyPersonalRange()
            }
        }
    }

    private var personalContent: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 20) {
                if let interval = try? personalRange.dateInterval() {
                    InAppEventListView(events: calendarManager.events, privacyMode: calendarManager.privacyMode,
                        dateInterval: interval, timeZone: TimeZone(identifier: personalRange.timeZoneIdentifier) ?? .current,
                        collapseEmptyDays: collapseEmptyDays)
                }
            }
            .padding(.top, 4)
        }
    }

    private var shareMenu: some View {
        Menu {
            Button { beginImage() } label: { Label("sharing.action.image", systemImage: "photo") }
                .disabled(sharedMode ? profile == nil : calendarManager.isLoading)
                .accessibilityIdentifier("home.share.image")
            Button {
                if sharedMode, let profile { subscriptionProfile = profile }
                else { showingCalendarPicker = true }
            } label: {
                Label(sharedMode ? LocalizedStringKey("sharing.action.link") : LocalizedStringKey("sharing.action.calendar"), systemImage: "link")
            }
            .accessibilityIdentifier("home.share.calendar")
        } label: { Image(systemName: "square.and.arrow.up") }
        .accessibilityLabel(Text("export.share"))
        .accessibilityIdentifier("home.share")
    }

    private var modeMenu: some View {
        Menu {
            Button { sharedMode = false } label: { Label("home.personal", systemImage: sharedMode ? "person" : "checkmark") }
                .accessibilityIdentifier("home.mode.personal")
            Button { beginEditor(nil) } label: { Label("home.addShared", systemImage: "calendar.badge.plus") }
                .accessibilityIdentifier("home.mode.addShared")
            ForEach(profiles) { value in
                Button { selectedProfileID = value.id.uuidString; sharedMode = true } label: {
                    if sharedMode && profile?.id == value.id { Label(value.name, systemImage: "checkmark") }
                    else { Text(value.name) }
                }
                .accessibilityIdentifier("home.shared.profile.\(value.name)")
            }
            if sharedMode, let profile {
                Button("browse.restore") { workspace.resetBrowse(profile: profile) }
                    .accessibilityIdentifier("home.browse.restore")
            }
        } label: { Image(systemName: "square.stack") }
        .accessibilityLabel(Text("home.mode")).accessibilityIdentifier("home.mode")
    }

    private var visibilityMenu: some View {
        Menu {
            if sharedMode {
                Button("browse.asShared") { updateBrowse { $0.displayMode = nil } }
                    .accessibilityIdentifier("home.shared.privacy.shared")
                    .accessibilityAddTraits(browse?.displayMode == nil ? .isSelected : [])
            }
            ForEach(PrivacyMode.allCases, id: \.self) { mode in
                let selected = sharedMode ? browse?.displayMode == mode : calendarManager.privacyMode == mode
                Button {
                    if sharedMode { updateBrowse { $0.displayMode = mode } }
                    else { calendarManager.updatePrivacyMode(mode) }
                } label: {
                    HStack {
                        if sharedMode && mode == .full { Text("browse.fullLocal") } else { Text(mode.localizedKey) }
                        if selected { Image(systemName: "checkmark") }
                    }
                }
                .accessibilityIdentifier("home.\(sharedMode ? "shared" : "personal").privacy.\(mode.rawValue)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        } label: { Image(systemName: "eye") }
        .accessibilityLabel(Text("accessibility.filter"))
        .accessibilityIdentifier(sharedMode ? "home.shared.privacy" : "home.personal.privacy")
    }

    private func updateBrowse(_ change: (inout ShareBrowseSettings)->Void) {
        guard let profile else { return }
        var value = workspace.browse(profileID: profile.id, defaultProfile: profile)
        change(&value)
        workspace.setBrowse(value, for: profile.id)
    }
    private func setViewingRange(_ range: SharedCalendarRange) {
        if sharedMode { updateBrowse { $0.range = range } }
        else { workspace.personalRange = range }
    }
    private func applyPersonalRange() {
        guard let interval = try? personalRange.dateInterval() else { return }
        calendarManager.updateDateRange(.custom(start: interval.start, endExclusive: interval.end))
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { LanguageSettingsView() } label: { Label("settings.language", systemImage: "globe") }
                    if sharedMode, let browse {
                        NavigationLink {
                            BrowseCalendarSelectionView(selectedIDs: browse.sourceCalendarIDs,
                                onChange: { ids in updateBrowse { $0.sourceCalendarIDs = ids } })
                        } label: { Text("settings.calendars") }
                        .accessibilityIdentifier("home.shared.sources")
                    } else {
                        NavigationLink { CalendarSelectionView(calendarManager: calendarManager) } label: { Text("settings.calendars") }
                            .accessibilityLabel(Text("accessibility.calendarSelection"))
                    }
                    NavigationLink {
                        SharedCalendarsView(defaultSourceIDs: currentSources, defaultPrivacyMode: .opaque)
                    } label: { Label("sharing.title", systemImage: "person.2.crop.square.stack") }
                    Toggle("settings.collapseEmptyDays", isOn: $collapseEmptyDays)
                    Text("settings.collapseEmptyDays.help").font(.caption).foregroundStyle(.secondary)
                }
                Section("section.appInfo") {
                    LabeledContent("app.version", value: appVersion)
                    LabeledContent("app.build", value: appBuild)
                    Button("settings.privacyPolicy") { showingPrivacyPolicy = true }
                }
            }
            .navigationTitle("settings.title")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("common.done") { showingSettings = false }.accessibilityIdentifier("home.settings.done")
            } }
            .sheet(isPresented: $showingPrivacyPolicy) { SafariView(url: privacyPolicyURL) }
        }
    }

    private func beginEditor(_ value: SharedCalendarProfile?, reviewBrowseChanges: Bool = false) {
        let viewing = (sharedMode ? browse : nil) ?? ShareBrowseSettings(range: personalRange, sourceCalendarIDs: currentSources, displayMode: nil)
        let reviewsScope = reviewBrowseChanges && value.map {
            viewing.range != $0.range || viewing.sourceCalendarIDs != $0.sourceCalendarIDs
        } == true
        editorPresentation = SharedEditorPresentation(profile: value, browse: viewing,
            defaultSourceIDs: currentSources, reviewsBrowseOnOpen: reviewsScope)
    }
    private func beginImage() {
        guard sharedMode || !calendarManager.isLoading else { return }
        guard !sharedMode || (profile != nil && browse != nil) else { return }
        imageContext = ImageContext(profileID: sharedMode ? profile?.id : nil, browse: sharedMode ? browse : nil,
            events: calendarManager.events, range: currentRange, privacy: calendarManager.privacyMode)
        imageUnsharedCount = sharedMode ? browsedEvents.filter { !$0.isIncluded }.count : 0
    }
    private func stageShare(_ items: [Any]) {
        pendingActivity = items
        imageContext = nil
        subscriptionProfile = nil
    }
    private func finishPresentation() {
        if let pendingActivity { activityItems = pendingActivity; self.pendingActivity = nil; showingActivity = true }
        else if let pendingSubscription { subscriptionProfile = pendingSubscription; self.pendingSubscription = nil }
        else if pendingNewCalendar { pendingNewCalendar = false; beginEditor(nil) }
    }

    @MainActor private func generateImage(_ scope: CalendarImageScope, context: ImageContext) async -> UIImage? {
        let list: AnyView
        do {
            if let id = context.profileID {
                guard let confirmed = sharedCalendarManager.profiles.first(where: { $0.id == id && !$0.pendingDeletion }) else { return nil }
                let events: [SharedEventPreview]
                let range: SharedCalendarRange
                let displayMode: PrivacyMode?
                let includeUnshared: Bool
                if scope == .confirmed {
                    events = try await sharedCalendarManager.preview(profileID: id)
                    range = confirmed.range; displayMode = nil; includeUnshared = false
                } else if let viewing = context.browse {
                    events = try await sharedCalendarManager.browsePreview(profileID: id, range: viewing.range, sourceCalendarIDs: viewing.sourceCalendarIDs)
                    range = viewing.range; displayMode = viewing.displayMode; includeUnshared = true
                    imageUnsharedCount = events.filter { !$0.isIncluded }.count
                } else { return nil }
                guard sharedCalendarManager.profiles.first(where: { $0.id == id })?.revision == confirmed.revision else { return nil }
                list = AnyView(InAppEventListView(sharedEvents: events, dateInterval: try range.dateInterval(),
                    timeZone: TimeZone(identifier: range.timeZoneIdentifier) ?? .current, collapseEmptyDays: collapseEmptyDays,
                    displayMode: displayMode, showsUnshared: includeUnshared, onSelect: { _ in }))
            } else {
                list = AnyView(InAppEventListView(events: context.events, privacyMode: context.privacy,
                    dateInterval: try context.range.dateInterval(), timeZone: TimeZone(identifier: context.range.timeZoneIdentifier) ?? .current,
                    collapseEmptyDays: collapseEmptyDays))
            }
            let width = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.width ?? 390
            exportManager.generatedImage = nil
            await exportManager.generateImage(from: AnyView(list.padding(.top, 4).frame(width: width)
                .background(Color(.systemBackground)).environment(\.dynamicTypeSize, dynamicTypeSize)), targetWidth: width, colorScheme: colorScheme)
            return exportManager.generatedImage
        } catch { return nil }
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

#Preview {
    ContentView()
        .environmentObject(LanguageManager())
        .environmentObject(SharedCalendarManager())
        .environmentObject(SharingWorkspace(defaults: nil))
}
