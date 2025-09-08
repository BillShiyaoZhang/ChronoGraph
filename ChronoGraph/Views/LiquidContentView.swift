// filepath: /Users/shiyaozhang/Developer/ChronoGraph/ChronoGraph/Views/LiquidContentView.swift
//  - 集成: 授权、日期范围、隐私模式、日历筛选、事件可视化、导出（多日/周网格）
//  - 生成图片后调用系统分享

import SwiftUI
import EventKit

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
    // Persist only collapse preference here; other prefs centralized in CalendarManager
    @AppStorage("pref.collapseEmptyDays") private var collapseEmptyDays: Bool = false

    enum ExportType { case multiDay, weekly }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) { contentLayer }
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
        Button { triggerExport(.multiDay) } label: { Image(systemName: "square.and.arrow.up") }
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
//                }
//                Section("显示设置") {
                    Toggle("折叠空白日期", isOn: $collapseEmptyDays)
                    Text("开启后空白日期仅显示标题行；关闭则显示“无事件”占位。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section("应用信息") {
                    HStack { Text("版本"); Spacer(); Text("1.0.0").foregroundColor(.secondary) }
                    HStack { Text("构建号"); Spacer(); Text("100").foregroundColor(.secondary) }
                }
                Section("数据 & 导出 (占位)") { Text("导出尺寸、主题、隐私策略稍后提供。").font(.caption) }
                Section("支持 (占位)") {
                    Button("反馈与建议") { }
                    Button("评分与评价") { }
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showingSettingsSheet = false } } }
        }
    }

    // MARK: - Export Logic (unchanged)
    private func triggerExport(_ type: ExportType) { exportType = type; Task { await generateExport(type) } }

    @MainActor private func generateExport(_ type: ExportType) async {
        switch type {
        case .multiDay:
            let view = AnyView(CalendarVisualizationView(events: calendarManager.events, privacyMode: calendarManager.privacyMode, dateRange: calendarManager.selectedDateRange, forExport: true).padding(24))
            await exportManager.generateImage(from: view, targetWidth: 1400, colorScheme: .light)
        case .weekly:
            let weekly = AnyView(WeeklyGridExportView(events: calendarManager.events, privacyMode: calendarManager.privacyMode, dateRange: .last7Days, preferSquare: preferSquareWeekly).padding(24))
            await exportManager.generateImage(from: weekly, targetWidth: 1400, colorScheme: .light)
        }
        exportManager.shareImage()
    }

    private func exportItems() -> [Any] { var items: [Any] = []; if let img = exportManager.generatedImage { items.append(img) }; return items }
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

#Preview {
    LiquidContentView()
}
