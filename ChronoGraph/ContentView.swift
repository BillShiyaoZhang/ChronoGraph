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
    @State private var showingCalendarPicker = false
    
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
            }
            .navigationTitle("ChronoGraph")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                settingsView
            }
            .sheet(isPresented: $showingCalendarPicker) {
                calendarSelectionView
            }
            .sheet(isPresented: $exportManager.showingShareSheet) {
                if let image = exportManager.generatedImage {
                    if let itemSource = ImageFileActivityItemSource(image: image, baseFilename: ExportFilenameHelper.suggestedBaseName(for: calendarManager.selectedDateRange)) {
                        ShareSheet(activityItems: [itemSource])
                    } else {
                        // Fallback: share UIImage directly
                        ShareSheet(activityItems: [image])
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                // Refresh auth state when returning from Settings
                calendarManager.refreshAuthorizationStatus()
            }
        }
    }
    
    // MARK: - 权限请求界面
    private var permissionRequestView: some View {
        VStack(spacing: 30) {
            Spacer()
            
            VStack(spacing: 20) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("欢迎使用 ChronoGraph")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("将您的日历转化为美观、私密的可视化图片")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 15) {
                FeatureRow(
                    icon: "eye.slash",
                    title: "隐私保护",
                    description: "完全控制显示的信息详细程度"
                )
                
                FeatureRow(
                    icon: "paintbrush",
                    title: "美学设计",
                    description: "精美的视觉输出，告别截图"
                )
                
                FeatureRow(
                    icon: "iphone",
                    title: "本地处理",
                    description: "数据永远不会离开您的设备"
                )
            }
            .padding(.horizontal, 40)
            
            Spacer()
            
            VStack(spacing: 12) {
                if calendarManager.isDeniedOrRestricted || calendarManager.isWriteOnly {
                    // 已拒绝或仅写入（iOS 17），引导去设置
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("前往设置开启“完整访问”")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.blue)
                            .cornerRadius(25)
                    }
                    
                    Text(calendarManager.isWriteOnly ? "当前为“仅写入”权限，无法读取日程内容。请在 设置 > 隐私与安全 > 日历 中为 ChronoGraph 启用“完整访问”。" : "您已拒绝日历权限。请在 设置 > 隐私与安全 > 日历 中为 ChronoGraph 启用“完整访问”。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    // 首次请求
                    Button {
                        Task { await calendarManager.requestCalendarAccess() }
                    } label: {
                        Text("允许访问日历")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.blue)
                            .cornerRadius(25)
                    }
                    
                    Text("我们需要读取您的日历来生成图片（仅在本地处理）。iOS 17 将读取权限标记为“完整访问”，不代表我们会修改您的数据。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 50)
        }
    }
    
    // MARK: - 主界面
    private var mainInterfaceView: some View {
        VStack(spacing: 0) {
            // 控制面板
            controlPanel
                .padding(.horizontal, 20)
                .padding(.vertical, 15)
                .background(Color(.systemGray6))
            
            // 日程预览（避免嵌套滚动）
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
    
    // MARK: - 控制面板
    private var controlPanel: some View {
        VStack(spacing: 15) {
            // 日期范围选择
            VStack(alignment: .leading, spacing: 8) {
                Text("时间范围")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(CalendarManager.DateRange.allCases, id: \.self) { range in
                            Button { calendarManager.updateDateRange(range) } label: {
                                Text(range.rawValue)
                                    .font(.subheadline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(
                                        calendarManager.selectedDateRange == range ?
                                        Color.blue : Color(.systemGray5)
                                    )
                                    .foregroundColor(
                                        calendarManager.selectedDateRange == range ?
                                        .white : .primary
                                    )
                                    .cornerRadius(20)
                            }
                        }
                    }
                    .padding(.horizontal, 5)
                }
            }
            
            // 隐私模式选择
            VStack(alignment: .leading, spacing: 8) {
                Text("隐私级别")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Picker("隐私模式", selection: $calendarManager.privacyMode) {
                    ForEach(PrivacyMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
            }
        }
    }
    
    // MARK: - 空状态视图
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
            
            Button { showingCalendarPicker = true } label: {
                Text("选择日历")
                    .font(.subheadline)
                    .foregroundColor(.blue)
            }
        }
        .padding(.horizontal, 40)
    }
    
    // MARK: - 底部操作栏
    private var bottomActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 20) {
                Button { showingCalendarPicker = true } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "calendar").font(.title2)
                        Text("日历").font(.caption)
                    }
                    .foregroundColor(.blue)
                }
                
                Spacer()
                
                Button {
                    Task {
                        // Choose grid-style weekly export for this week/next week
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
                            // Use a square-friendly width for better readability when sharing
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
                        if exportManager.isGeneratingImage {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
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
                
                Button {
                    // TODO: 实现更多功能
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "ellipsis").font(.title2)
                        Text("更多").font(.caption)
                    }
                    .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 20)
            .background(Color(.systemBackground))
        }
    }
    
    // MARK: - 设置界面
    private var settingsView: some View {
        NavigationStack {
            List {
                Section("应用信息") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("隐私政策")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.secondary)
                    }
                }
                Section("支持") {
                    HStack {
                        Text("反馈建议")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showingSettings = false } } }
        }
    }
    
    // MARK: - 日历选择界面
    private var calendarSelectionView: some View {
        NavigationStack {
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
            .navigationTitle("选择日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showingCalendarPicker = false } } }
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
