// filepath: /Users/shiyaozhang/Developer/ChronoGraph/ChronoGraph/Views/LiquidContentView.swift
//  - 集成: 授权、日期范围、隐私模式、日历筛选、事件可视化、导出（多日/周网格）
//  - 生成图片后调用系统分享

import SwiftUI
import EventKit
import SafariServices

struct LiquidContentView: View {
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
                .accessibilityLabel("设置")
        }
    }

    private var shareToolbarItem: some View {
        Button { triggerExport(.list) } label: { Image(systemName: "square.and.arrow.up") }
            .accessibilityLabel("导出")
    }

    private var dateSelectionToolbarItem: some View {
        Menu {
            Section("日期范围") {
                ForEach(CalendarManager.DateRange.allCases, id: \.self) { range in
                    Button { calendarManager.updateDateRange(range) } label: {
                        HStack { Text(range.rawValue); if range == calendarManager.selectedDateRange { Image(systemName: "checkmark") } }
                    }
                }
            }
        } label: {
            Image(systemName: "calendar")
            Text(calendarManager.selectedDateRange.rawValue)
        }
        .accessibilityLabel("日期范围选择")
    }

    private var privacyModeToolbarItem: some View {
        Menu {
            Section("显示模式") {
                ForEach(PrivacyMode.allCases, id: \.self) { mode in
                    Button { calendarManager.updatePrivacyMode(mode) } label: {
                        HStack { Text(mode.rawValue); if mode == calendarManager.privacyMode { Image(systemName: "checkmark") } }
                    }
                }
            }
        } label: {
            Image(systemName: "eye")
            Text(calendarManager.privacyMode.rawValue)
        }
        .accessibilityLabel("筛选")
    }
    
    // MARK: - Authorization States
        private var requestAccessView: some View {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "calendar.badge.plus").font(.system(size: 54)).symbolRenderingMode(.hierarchical).foregroundColor(.accentColor)
                Text("需要访问日历").font(.title2).fontWeight(.semibold)
                Text("授予读取权限后即可生成可视化和导出图片。").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button {
                    isRequestingAuth = true
                    Task { await calendarManager.requestCalendarAccess(); isRequestingAuth = false }
                } label: {
                    Text(isRequestingAuth ? "请求中…" : "授权访问")
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
                Text("访问被拒绝").font(.title2).fontWeight(.semibold)
                Text("请前往“设置 > 隐私 > 日历”重新授权。").font(.subheadline).foregroundColor(.secondary)
                Button("刷新状态") { calendarManager.refreshAuthorizationStatus() }
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
                    NavigationLink { CalendarSelectionView(calendarManager: calendarManager) } label: {
                        HStack {
                            Text("日历")
                            Spacer()
                            if !calendarManager.isAuthorizedForRead { Text("未授权").foregroundColor(.secondary).font(.caption) }
                        }
                    }
                    .accessibilityLabel("日历选择入口")

                    Toggle("折叠空白日期", isOn: $collapseEmptyDays)
                    
                    Text("开启后空白日期仅显示标题行；关闭则显示“无事件”占位。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("应用信息") {
                    HStack { Text("版本"); Spacer(); Text("0.1.0").foregroundColor(.secondary) }
                    HStack { Text("构建号"); Spacer(); Text("1").foregroundColor(.secondary) }
                    Button("隐私政策") { showingPrivacyPolicy = true }
                }
                Section("支持 (占位)") {
                    Button("反馈与建议") { }
                    Button("评分与评价") { }
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showingSettingsSheet = false } } }
            .sheet(isPresented: $showingPrivacyPolicy) { SafariView(url: privacyPolicyURL) }
        }
    }

    // MARK: - Export Logic (modified for WYSIWYG long image)
    private func triggerExport(_ type: ExportType) { exportType = type; Task { await generateExport(type) } }

    @MainActor private func generateExport(_ type: ExportType) async {
        // Helper to provide a safe fallback width before geometry resolved
        func fallbackWidth() -> CGFloat { max(contentWidth, 390) } // 390 ~ iPhone 14 width
        switch type {
        case .list:
            let width = fallbackWidth()
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
    LiquidContentView()
}
