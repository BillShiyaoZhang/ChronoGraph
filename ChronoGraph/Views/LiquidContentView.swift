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
    // 新增：设置页显示状态 & 示例开关
    @State private var showingSettingsSheet = false
    @State private var sampleToggleA = true
    @State private var sampleToggleB = false

    enum ExportType { case multiDay, weekly }

    // MARK: - Body
    var body: some View {
        NavigationStack { // 包裹以使用 toolbar
            ZStack(alignment: .bottom) {
                // Do not remove the below commented logic; it's for future use when re-adding auth states
//                if calendarManager.isDeniedOrRestricted {
//                    deniedView
//                } else if !calendarManager.isAuthorizedForRead && !isRequestingAuth {
//                    requestAccessView
//                } else {
//                    contentLayer
//                }
                contentLayer
            }
        }
    }

    // MARK: - Layers
    private var contentLayer: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                CalendarVisualizationView(
                    events: calendarManager.events,
                    privacyMode: calendarManager.privacyMode,
                    dateRange: calendarManager.selectedDateRange
                )
                .id(calendarManager.selectedDateRange) // 重置滚动定位
            }
        }
        .sheet(isPresented: $exportManager.showingShareSheet) { ExportShareSheet(activityItems: exportItems()) }
        .task { calendarManager.refreshAuthorizationStatus() }
        .animation(.spring(duration: 0.35, bounce: 0.18), value: calendarManager.events.count)
        .animation(.easeInOut(duration: 0.25), value: calendarManager.privacyMode)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Spacer()
                
                filterMenuToolbarItem
                
                Button { triggerExport(.multiDay) } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出")
            }
            
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingSettingsSheet = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $showingSettingsSheet) { settingsSheet }
    }

    // MARK: - Header (保留未使用)
    private var headerInfo: some View {
        // ...existing code...
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                Text("ChronoGraph").font(.largeTitle).fontWeight(.bold)
                if calendarManager.isLoading { ProgressView().progressViewStyle(.circular) }
                Spacer()
                privacyModeBadge
            }
            secondaryChips
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .blendMode(.overlay)
        )
    }

    private var privacyModeBadge: some View {
        // ...existing code...
        Button { showingPrivacySheet = true } label: {
            HStack(spacing: 6) {
                Image(systemName: calendarManager.privacyMode.systemImage)
                Text(calendarManager.privacyMode.rawValue)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPrivacySheet) { privacyPickerSheet }
    }

    private var secondaryChips: some View {
        // ...existing code...
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { showingCalendarPicker = true } label: {
                    chipLabel(icon: "list.bullet", text: "日历 (\(calendarManager.selectedCalendars.count))")
                }
                .sheet(isPresented: $showingCalendarPicker) { calendarPickerSheet }
                Button { triggerExport(.multiDay) } label: { chipLabel(icon: "square.and.arrow.up.on.square", text: "导出视图") }
                Button { triggerExport(.weekly) } label: { chipLabel(icon: "rectangle.grid.3x2", text: "周网格") }
            }
            .padding(.horizontal, 4)
        }
    }

    private func chipLabel(icon: String, text: String) -> some View {
        // ...existing code...
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption)
        .foregroundColor(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    // MARK: - Bottom Glass Bar
    private var bottomBar: some View {
        ZStack {
//            HStack { Spacer(); exportButton; Spacer() }
            exportButton
        }
        .padding(.horizontal, 16)
    }

    private var exportButton: some View {
        // ...existing code...
        Button { triggerExport(.multiDay) } label: { labelPill(icon: "square.and.arrow.up", title: "导出") }
            .buttonStyle(.glass)
    }

    // MARK: - Toolbar Items
    private var filterMenuToolbarItem: some View {
        Menu {
            Section("日期范围") {
                ForEach(CalendarManager.DateRange.allCases, id: \.self) { range in
                    Button { updateRange(range) } label: {
                        HStack {
                            Text(range.rawValue)
                            if range == calendarManager.selectedDateRange { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Section("隐私模式") {
                ForEach(PrivacyMode.allCases, id: \.self) { mode in
                    Button { calendarManager.updatePrivacyMode(mode) } label: {
                        HStack {
                            Text(mode.rawValue)
                            if mode == calendarManager.privacyMode { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("筛选")
    }

    private var dateRangeInlinePicker: some View { EmptyView() }

    private var exportInlineButtons: some View {
        // ...existing code...
        HStack(spacing: 10) {
            Button { triggerExport(.multiDay) } label: { labelPill(icon: "square.and.arrow.up", title: "导出") }
        }
    }

    private var calendarInlineMenu: some View {
        // ...existing code...
        Menu {
            Section("切换日历") {
                ForEach(calendarManager.calendars, id: \.calendarIdentifier) { cal in
                    let selected = calendarManager.selectedCalendars.contains(cal.calendarIdentifier)
                    Button { calendarManager.toggleCalendarSelection(cal.calendarIdentifier) } label: {
                        Label(cal.title, systemImage: selected ? "checkmark.circle.fill" : "circle")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(Color(cgColor: cal.cgColor))
                    }
                }
            }
            Button("全选") { selectAllCalendars() }
            Button("清空") { clearAllCalendars() }
        } label: { labelPill(icon: "list.bullet", title: "日历") }
    }

    private func labelPill(icon: String, title: String) -> some View {
        // ...existing code...
        HStack(spacing: 6) { Image(systemName: icon); Text(title) }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    // MARK: - Authorization States
    private var requestAccessView: some View {
        // ...existing code...
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
            footerWatermark
        }
        .padding(.bottom, 40)
        .padding(.horizontal, 24)
    }

    private var deniedView: some View {
        // ...existing code...
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.slash").font(.system(size: 52)).foregroundColor(.secondary)
            Text("访问被拒绝").font(.title2).fontWeight(.semibold)
            Text("请前往“设置 > 隐私 > 日历”重新授权。").font(.subheadline).foregroundColor(.secondary)
            Button("刷新状态") { calendarManager.refreshAuthorizationStatus() }
                .padding(.top, 4)
            Spacer()
            footerWatermark
        }
        .padding(.bottom, 40)
        .padding(.horizontal, 24)
    }

    private var footerWatermark: some View {
        // ...existing code...
        VStack(spacing: 6) {
            Image(systemName: "clock.badge.checkmark").font(.caption).foregroundColor(.secondary)
            Text("ChronoGraph").font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: - Sheets
    private var privacyPickerSheet: some View {
        // ...existing code...
        NavigationStack {
            List {
                Section("隐私模式") {
                    ForEach(PrivacyMode.allCases, id: \.self) { mode in
                        HStack {
                            Label(mode.rawValue, systemImage: mode.systemImage)
                            Spacer()
                            if mode == calendarManager.privacyMode { Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { calendarManager.updatePrivacyMode(mode); dismissPresentedSheets() }
                        Text(mode.description).font(.caption).foregroundColor(.secondary).padding(.leading, 30)
                    }
                }
            }
            .navigationTitle("隐私显示")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismissPresentedSheets() } } }
        }
    }

    private var calendarPickerSheet: some View {
        // ...existing code...
        NavigationStack {
            List {
                Section("可用日历") {
                    ForEach(calendarManager.calendars, id: \.calendarIdentifier) { cal in
                        let selected = calendarManager.selectedCalendars.contains(cal.calendarIdentifier)
                        HStack {
                            Circle()
                                .fill(Color(cgColor: cal.cgColor))
                                .frame(width: 10, height: 10)
                            Text(cal.title)
                            Spacer()
                            if selected { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { calendarManager.toggleCalendarSelection(cal.calendarIdentifier) }
                    }
                }
                Section {
                    Button("全选") { selectAllCalendars() }
                    Button("清空") { clearAllCalendars() }
                }
            }
            .navigationTitle("选择日历")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismissPresentedSheets() } } }
        }
    }

    // 新增：设置页
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("应用信息") {
                    HStack { Text("版本"); Spacer(); Text("1.0.0").foregroundColor(.secondary) }
                    HStack { Text("构建号"); Spacer(); Text("100").foregroundColor(.secondary) }
                }
                Section("显示设置 (占位)") {
                    Toggle("启用示例功能A", isOn: $sampleToggleA)
                    Toggle("启用示例功能B", isOn: $sampleToggleB)
                    Text("更多显示相关设置将在后续添加…").font(.caption).foregroundColor(.secondary)
                }
                Section("数据 & 导出 (占位)") {
                    Text("将来这里可配置导出尺寸、主题、隐私替换策略等。").font(.caption)
                }
                Section("支持 (占位)") {
                    Button("反馈与建议") { /* 未来实现 */ }
                    Button("评分与评价") { /* 未来实现 */ }
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showingSettingsSheet = false } } }
        }
    }

    // MARK: - Export Logic
    private func triggerExport(_ type: ExportType) {
        // ...existing code...
        exportType = type
        Task { await generateExport(type) }
    }

    @MainActor
    private func generateExport(_ type: ExportType) async {
        // ...existing code...
        switch type {
        case .multiDay:
            let view = AnyView(
                CalendarVisualizationView(
                    events: calendarManager.events,
                    privacyMode: calendarManager.privacyMode,
                    dateRange: calendarManager.selectedDateRange,
                    forExport: true
                )
                .padding(24)
            )
            await exportManager.generateImage(from: view, targetWidth: 1400, colorScheme: .light)
        case .weekly:
            let weekly = AnyView(
                WeeklyGridExportView(
                    events: calendarManager.events,
                    privacyMode: calendarManager.privacyMode,
                    dateRange: .thisWeek,
                    preferSquare: preferSquareWeekly
                )
                .padding(24)
            )
            await exportManager.generateImage(from: weekly, targetWidth: 1400, colorScheme: .light)
        }
        exportManager.shareImage()
    }

    private func exportItems() -> [Any] {
        // ...existing code...
        var items: [Any] = []
        if let img = exportManager.generatedImage { items.append(img) }
        return items
    }

    // MARK: - Helpers
    private func updateRange(_ range: CalendarManager.DateRange) { calendarManager.updateDateRange(range) }
    private func selectAllCalendars() { calendarManager.selectedCalendars = Set(calendarManager.calendars.map { $0.calendarIdentifier }); calendarManager.loadEvents() }
    private func clearAllCalendars() { calendarManager.selectedCalendars.removeAll(); calendarManager.loadEvents() }
    private func dismissPresentedSheets() { showingCalendarPicker = false; showingPrivacySheet = false }
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
