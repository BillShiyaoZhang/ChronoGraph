import SwiftUI

/// Display selection and received-calendar management share the same explicit removal flow.
struct CloudReceivedCalendarRemovalView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let source: CloudSharedSource
    @State private var scope: String?
    @State private var token: String?
    @State private var isRemoving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("cloud.received.remove.calendar", value: source.name)
                LabeledContent("cloud.received.remove.owner", value: source.ownerName)
            }
            Section {
                Text("cloud.received.remove.effect")
                Text("cloud.received.remove.receiveAgain").foregroundStyle(.secondary)
            }
            Section {
                if isRemoving { ProgressView() }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("cloud.received.remove.error")
                    Button("cloud.received.remove.retry", role: .destructive) { remove() }
                        .disabled(!canRemove).accessibilityIdentifier("cloud.received.remove.retry")
                } else {
                    Button("cloud.received.remove.confirm", role: .destructive) { remove() }
                        .disabled(!canRemove).accessibilityIdentifier("cloud.received.remove.confirm")
                }
            }
        }
        .accessibilityIdentifier("cloud.received.remove.form")
        .navigationTitle("cloud.received.remove.title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button("common.cancel") { dismiss() }.disabled(isRemoving)
                .accessibilityIdentifier("cloud.received.remove.cancel")
        } }
        .interactiveDismissDisabled(isRemoving)
        .onAppear { scope = cloud.homeDisplayScope; token = cloud.session?.accessToken }
        .onChange(of: cloud.homeDisplayScope) { _, _ in dismiss() }
        .onChange(of: cloud.session?.accessToken) { _, _ in dismiss() }
    }

    private var canRemove: Bool {
        !isRemoving && !cloud.isRemovingReceivedSource && scope != nil && token != nil
            && cloud.homeDisplayScope == scope && cloud.session?.accessToken == token
            && source.ownerId != cloud.currentUserID && cloud.sharedSources.contains { $0.id == source.id }
    }

    private func remove() {
        guard canRemove else { return }
        isRemoving = true
        errorMessage = nil
        Task {
            let removed = await cloud.removeReceivedSource(sourceID: source.id)
            guard cloud.homeDisplayScope == scope, cloud.session?.accessToken == token else { dismiss(); return }
            isRemoving = false
            if removed { dismiss() }
            else { errorMessage = cloud.removeReceivedSourceError ?? String(localized: "cloud.received.remove.failed") }
        }
    }
}
