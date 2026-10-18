import SwiftUI
import UIKit

enum CalendarImageScope: String, CaseIterable, Identifiable, Sendable {
    case confirmed, currentView
    var id: String { rawValue }
}

@MainActor
struct CalendarImagePreview: View {
    let isShared: Bool
    let unsharedEventCount: Int
    private let generate: @MainActor (CalendarImageScope) async -> UIImage?
    private let onShare: (UIImage) -> Void
    @State private var scope: CalendarImageScope
    @State private var image: UIImage?
    @State private var renderedScope: CalendarImageScope?
    @State private var isGenerating = false
    @State private var failed = false
    @State private var retryID = UUID()

    init(isShared: Bool, unsharedEventCount: Int = 0,
         generate: @escaping @MainActor (CalendarImageScope) async -> UIImage?,
         onShare: @escaping (UIImage) -> Void) {
        self.isShared = isShared
        self.unsharedEventCount = max(0, unsharedEventCount)
        self.generate = generate
        self.onShare = onShare
        _scope = State(initialValue: isShared ? .confirmed : .currentView)
    }

    private var generationKey: String { "\(scope.rawValue)|\(retryID.uuidString)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isShared {
                    Picker("share.image.scope", selection: $scope) {
                        Text("share.image.confirmed").tag(CalendarImageScope.confirmed)
                        Text("share.image.currentView").tag(CalendarImageScope.currentView)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("share.image.scope")
                    if scope == .confirmed {
                        Text("share.image.confirmed.help").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(String(format: NSLocalizedString("share.image.currentView.help", comment: "Unshared event count"), unsharedEventCount))
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("share.image.unsharedCount")
                    }
                }
                if isGenerating {
                    ProgressView("share.image.loading").frame(maxWidth: .infinity, minHeight: 140)
                } else if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text("share.image.previewLabel"))
                        .accessibilityIdentifier("share.image.preview")
                } else if failed {
                    ContentUnavailableView("share.image.failed", systemImage: "photo.badge.exclamationmark")
                    Button("share.image.retry") { retryID = UUID() }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .navigationTitle("share.image.title")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    if let image, !isGenerating, renderedScope == scope { onShare(image) }
                } label: {
                    Label("share.image.send", systemImage: "square.and.arrow.up")
                }
                .disabled(image == nil || isGenerating || renderedScope != scope)
                .accessibilityIdentifier("share.image.send")
            }
        }
        .task(id: generationKey) {
            let requestedScope = scope
            isGenerating = true
            failed = false
            image = nil
            renderedScope = nil
            let result = await generate(requestedScope)
            guard !Task.isCancelled, requestedScope == scope else { return }
            image = result
            renderedScope = requestedScope
            failed = result == nil
            isGenerating = false
        }
    }
}
