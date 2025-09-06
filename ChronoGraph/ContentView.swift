//
//  ContentView.swift
//  ChronoGraph
//
//  Created by Shiyao Zhang on 05/09/2025.
//

import SwiftUI
import EventKit
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var calendarManager = CalendarManager()
    @StateObject private var exportManager = ImageExportManager()
    @State private var showingSettings = false
    // 新增: 筛选面板显示状态
    @State private var showingFilterSheet = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Check for proper authorization status based on iOS version
                if !calendarManager.isAuthorizedForRead {
                    // 权限请求界面
                    permissionRequestView
                } else {
                    // 主界面
                    mainInterfaceView
                }
//                    permissionRequestView
//                } else {
//                    // 主界面
//                    mainInterfaceView
//                }
                // for dev preview, always show main interface
                mainInterfaceView
            }
            .navigationTitle("ChronoGraph")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape.fill") }
                }
            }
            .sheet(isPresented: $showingSettings) { settingsView }
            .sheet(isPresented: $exportManager.showingShareSheet) {
                if let image = exportManager.generatedImage {
                    if let itemSource = ImageFileActivityItemSource(image: image, baseFilename: ExportFilenameHelper.suggestedBaseName(for: calendarManager.selectedDateRange)) {
                        ShareSheet(activityItems: [itemSource])
                    } else {
                        ShareSheet(activityItems: [image])
                    }
                }
            }
            // 新增: 筛选面板 Sheet
            .sheet(isPresented: $showingFilterSheet) { filterSheetView }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                calendarManager.refreshAuthorizationStatus()
            }
        }
    }
    
    // MARK: - 主界面
    private var mainInterfaceView: some View {
        VStack(spacing: 0) {
            // 原顶部控制面板已移除，改为底部“筛选”按钮触发 sheet
            Group {
                if calendarManager.isLoading {
                    ProgressView("正在加载日程...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, 100)
                } else if calendarManager.events.isEmpty {
                    emptyStateView
                        .padding(.top, 100)
                } else {
                    CalendarVisualizationView(
                        events: calendarManager.events,
                        privacyMode: calendarManager.privacyMode,
                        dateRange: calendarManager.selectedDateRange
                    )
                }
            }
            // 底部操作栏
            bottomActionBar
        }
    }
    
    // MARK: - 空状态视图（保持不变）
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("没有找到日程")
                .font(.title2)
                .fontWeight(.medium)
            Text("在选定的时间范围内没有日程安排")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button { showingSettings = true } label: {
                Text("前往设置选择日历")
                    .font(.subheadline)
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - 底部操作栏（替换“更多”为“筛选”）
    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 20) {
                Spacer()
                Button {
                    Task {
                        let visualizationView: AnyView
                        var exportWidth: CGFloat? = nil
                        switch calendarManager.selectedDateRange {
                        case .thisWeek, .nextWeek:
                            visualizationView = AnyView(
                                WeeklyGridExportView(
                                    events: calendarManager.events,
                                    privacyMode: calendarManager.privacyMode,
                                    dateRange: calendarManager.selectedDateRange,
                                    preferSquare: true
                                )
                            )
                            exportWidth = 1200
                        default:
                            visualizationView = AnyView(
                                CalendarVisualizationView(
                                    events: calendarManager.events,
                                    privacyMode: calendarManager.privacyMode,
                                    dateRange: calendarManager.selectedDateRange,
                                    forExport: true
                                )
                            )
                        }
                        await exportManager.generateImage(from: visualizationView, targetWidth: exportWidth)
                        exportManager.shareImage()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if exportManager.isGeneratingImage { ProgressView().scaleEffect(0.8) } else { Image(systemName: "square.and.arrow.up") }
                        Text("导出分享").fontWeight(.medium)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        calendarManager.events.isEmpty || exportManager.isGeneratingImage ? Color.gray : Color.blue
                    )
                    .cornerRadius(25)
                }
                .disabled(calendarManager.events.isEmpty || exportManager.isGeneratingImage)
                Spacer()
                Button { showingFilterSheet = true } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle").font(.title2)
                        Text("筛选").font(.caption)
                    }
                    .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 20)
            .background(Color(.systemBackground))
        }
    }
    
    // MARK: - 筛选 Sheet 内容（包含时间范围 & 隐私级别）
    private var filterSheetView: some View {
        FilterSheet(calendarManager: calendarManager)
    }
    
    // MARK: - 设置界面（保持不变）
    private var settingsView: some View {
        NavigationStack {
            List {
                Section("日程") {
                    NavigationLink {
                        CalendarSelectionSettingsView(calendarManager: calendarManager)
                    } label: {
                        HStack {
                            Text("日历")
                            Spacer()
                            Text(calendarManager.selectedCalendars.count == calendarManager.calendars.count ? "全部" : "\(calendarManager.selectedCalendars.count) 个")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Section("应用信息") {
                    HStack { Text("版本"); Spacer(); Text("1.0.0").foregroundColor(.secondary) }
                    HStack { Text("隐私政策"); Spacer(); Image(systemName: "chevron.right").foregroundColor(.secondary) }
                }
                Section("支持") {
                    HStack { Text("反馈建议"); Spacer(); Image(systemName: "chevron.right").foregroundColor(.secondary) }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showingSettings = false } } }
        }
    }
}

// 新增: 筛选面板 View
private struct FilterSheet: View {
    @ObservedObject var calendarManager: CalendarManager
    @Environment(\.dismiss) private var dismiss
    @State private var localPrivacy: PrivacyMode = .partial // was .normal (invalid)
    @State private var localRange: CalendarManager.DateRange = .today
    
    init(calendarManager: CalendarManager) {
        self.calendarManager = calendarManager
        _localPrivacy = State(initialValue: calendarManager.privacyMode)
        _localRange = State(initialValue: calendarManager.selectedDateRange)
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // 时间范围
                    VStack(alignment: .leading, spacing: 12) {
                        Text("时间范围").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(CalendarManager.DateRange.allCases, id: \.self) { range in
                                    Button { localRange = range } label: {
                                        Text(range.rawValue)
                                            .font(.subheadline)
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 10)
                                            .background(localRange == range ? Color.blue : Color(.systemGray5))
                                            .foregroundColor(localRange == range ? .white : .primary)
                                            .cornerRadius(22)
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    // 隐私级别
                    VStack(alignment: .leading, spacing: 12) {
                        Text("隐私级别").font(.headline)
                        Picker("隐私模式", selection: $localPrivacy) {
                            ForEach(PrivacyMode.allCases, id: \.self) { mode in
                                Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                    Spacer(minLength: 10)
                    // 操作按钮
                    Button {
                        // 应用选择
                        if calendarManager.selectedDateRange != localRange { calendarManager.updateDateRange(localRange) }
                        if calendarManager.privacyMode != localPrivacy { calendarManager.privacyMode = localPrivacy }
                        dismiss()
                    } label: {
                        Text("应用并关闭")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .navigationTitle("筛选")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
        }
    }
}

// MARK: - 辅助视图
struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(description).font(.subheadline).foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

// MARK: - Image sharing helpers
final class ImageFileActivityItemSource: NSObject, UIActivityItemSource {
    private let image: UIImage
    private let fileURL: URL
    private let utiIdentifier: String

    init?(image: UIImage, baseFilename: String = "ChronoGraph") {
        self.image = image

        // Downscale very large images before encoding to reduce size and memory
        let maxShareDimension: CGFloat = 3000 // cap longest side at ~3000px
        let preparedImage = ImageFileActivityItemSource.downscaledIfNeeded(image, maxDimension: maxShareDimension)
        
        // Prefer JPEG with reasonable quality; fallback to PNG only if JPEG fails
        let filename: String
        let data: Data
        if let jpeg = preparedImage.jpegData(compressionQuality: 0.82) {
            data = jpeg
            filename = baseFilename.appending(".jpg")
            self.utiIdentifier = UTType.jpeg.identifier
        } else if let png = preparedImage.pngData() {
            data = png
            filename = baseFilename.appending(".png")
            self.utiIdentifier = UTType.png.identifier
        } else {
            return nil
        }

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent(filename)
        do { try data.write(to: url, options: [.atomic]) } catch { return nil }
        self.fileURL = url
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { fileURL }
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { fileURL }
    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { utiIdentifier }
    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String { "ChronoGraph Export" }
    func activityViewControllerThumbnailImage(forActivityType activityType: UIActivity.ActivityType?, suggestedSize size: CGSize) -> UIImage? { image }

    private static func downscaledIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        
        // Use opaque renderer to match our solid background; improves JPEG results
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // render at 1x into the target pixel size
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let down = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return down
    }
}

enum ExportFilenameHelper {
    static func suggestedBaseName(for range: CalendarManager.DateRange) -> String {
        // Provide a stable, ASCII-only base filename for better cross-app compatibility
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let datePart = formatter.string(from: Date())
        let rangeKey: String = {
            switch range {
            case .today: return "today"
            case .tomorrow: return "tomorrow"
            case .thisWeek: return "this-week"
            case .nextWeek: return "next-week"
            case .custom: return "custom"
            }
        }()
        return "ChronoGraph_\(rangeKey)_\(datePart)"
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}

// MARK: - 新日历选择视图
struct CalendarSelectionSettingsView: View {
    @ObservedObject var calendarManager: CalendarManager
    var body: some View {
        List {
            ForEach(calendarManager.calendars, id: \.calendarIdentifier) { calendar in
                HStack {
                    Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 12, height: 12)
                    Text(calendar.title)
                    Spacer()
                    if calendarManager.selectedCalendars.contains(calendar.calendarIdentifier) {
                        Image(systemName: "checkmark").foregroundColor(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { calendarManager.toggleCalendarSelection(calendar.calendarIdentifier) }
            }
        }
        .navigationTitle("日历")
        .navigationBarTitleDisplayMode(.inline)
    }
}
