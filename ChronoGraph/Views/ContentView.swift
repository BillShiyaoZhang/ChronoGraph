//  ContentView.swift
//  ChronoGraph
//
//  Main content: authorization, date range, privacy mode, calendar selection, event list, export

import SwiftUI
import EventKit
import SafariServices

struct ContentView: View {
    // MARK: - State / Managers
    @StateObject private var calendarManager = CalendarManager()
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

    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-" }
    private var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-" }

    // Future hosted privacy policy URL (placeholder)
    private let privacyPolicyURL = URL(string: "https://github.com/BillShiyaoZhang/ChronoGraph/blob/main/隐私政策.md")!

    enum ExportType { case list }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if calendarManager.isDeniedOrRestricted {
                    deniedView
                } else if !calendarManager.isAuthorizedForRead && !isRequestingAuth {
                    requestAccessView
                } else {
                    contentLayer
                }
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
        .sheet(isPresented: $exportManager.showingShareSheet) { ExportShareSheet(activityItems: exportItems()) }
        .task { calendarManager.refreshAuthorizationStatus() }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettingsSheet) { settingsSheet }
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            privacyModeToolbarItem
            dateSelectionToolbarItem
            Spacer()
            shareToolbarItem
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showingSettingsSheet = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel(Text("settings.title"))
        }
    }

    private var shareToolbarItem: some View {
        Button { triggerExport(.list) } label: { Image(systemName: "square.and.arrow.up") }
            .accessibilityLabel(Text("export.share"))
    }

    private var dateSelectionToolbarItem: some View {
        Menu {
            Section("section.dateRange") {
                ForEach(CalendarManager.DateRange.allCases, id: \.self) { (range: CalendarManager.DateRange) in
                    Button { calendarManager.updateDateRange(range) } label: {
                        HStack { Text(range.localizedKey); if range == calendarManager.selectedDateRange { Image(systemName: "checkmark") } }
                    }
                }
            }
        } label: {
            Image(systemName: "calendar")
            Text(calendarManager.selectedDateRange.localizedKey)
        }
        .accessibilityLabel(Text("accessibility.dateRangePicker"))
    }

    private var privacyModeToolbarItem: some View {
        Menu {
            Section("section.privacyMode") {
                ForEach(PrivacyMode.allCases, id: \.self) { (mode: PrivacyMode) in
                    Button { calendarManager.updatePrivacyMode(mode) } label: {
                        HStack { Text(mode.localizedKey); if mode == calendarManager.privacyMode { Image(systemName: "checkmark") } }
                    }
                }
            }
        } label: {
            Image(systemName: "eye")
            Text(calendarManager.privacyMode.localizedKey)
        }
        .accessibilityLabel(Text("accessibility.filter"))
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
                    NavigationLink { CalendarSelectionView(calendarManager: calendarManager) } label: {
                        HStack {
                            Text("settings.calendars")
                            Spacer()
                            if !calendarManager.isAuthorizedForRead { Text("status.unauthorized").foregroundColor(.secondary).font(.caption) }
                        }
                    }
                    .accessibilityLabel(Text("accessibility.calendarSelection"))

                    Toggle("settings.collapseEmptyDays", isOn: $collapseEmptyDays)
                    
                    Text("settings.collapseEmptyDays.help")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("section.appInfo") {
                    HStack { Text("app.version"); Spacer(); Text(appVersion).foregroundColor(.secondary) }
                    HStack { Text("app.build"); Spacer(); Text(appBuild).foregroundColor(.secondary) }
                    Button("settings.privacyPolicy") { showingPrivacyPolicy = true }
                }
                Section("section.support") {
                    Button("settings.feedback") { }
                    Button("settings.rate") { }
                }
            }
            .navigationTitle(Text("settings.title"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("common.done") { showingSettingsSheet = false } } }
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
            let identicalList = AnyView(
                InAppEventListView(
                    events: calendarManager.events,
                    privacyMode: calendarManager.privacyMode,
                    dateRange: calendarManager.selectedDateRange,
                    collapseEmptyDays: collapseEmptyDays
                )
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
    private func selectAllCalendars() { calendarManager.selectedCalendars = Set(calendarManager.calendars.map { $0.calendarIdentifier }); calendarManager.loadEvents() }
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

#Preview {
    ContentView()
}
