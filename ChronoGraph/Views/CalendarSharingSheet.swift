import SwiftUI

@MainActor
struct SubscriptionSharingView: View {
    @EnvironmentObject private var manager: SharedCalendarManager
    let profile: SharedCalendarProfile
    let hasDraft: Bool
    private let suppliedStore: SubscriptionLinkStore?
    private let onShare: (URL) -> Void
    @State private var store: SubscriptionLinkStore?
    @State private var input = ""
    @State private var savedURL: URL?
    @State private var loadedBinding: String?
    @State private var errorMessage: String?
    @State private var showingGuide = false
    @State private var isChangingLink = false
    @FocusState private var isEditingLink: Bool

    init(profile: SharedCalendarProfile, hasDraft: Bool, linkStore: SubscriptionLinkStore? = nil,
         onShare: @escaping (URL) -> Void) {
        self.profile = profile
        self.hasDraft = hasDraft
        suppliedStore = linkStore
        self.onShare = onShare
    }

    private var bindingKey: String { "\(profile.id.uuidString)|\(profile.targetCalendarID ?? "none")" }
    private var hasTarget: Bool {
        manager.inventoryIsAvailable && !profile.pendingDeletion &&
        manager.calendars.contains { $0.id == profile.targetCalendarID && $0.sourceID == profile.targetSourceID }
    }
    private var canSend: Bool {
        !isChangingLink && hasTarget && loadedBinding == bindingKey && savedURL != nil &&
            input.trimmingCharacters(in: .whitespacesAndNewlines) == savedURL?.absoluteString
    }

    var body: some View {
        Form {
            if let savedURL, !isChangingLink {
                Section {
                    Button {
                        if canSend { onShare(savedURL) }
                    } label: {
                        Label("share.calendar.link.send", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                    .accessibilityIdentifier("share.calendar.link.send")
                    Label("share.calendar.link.saved", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } header: { Text(profile.name) }
                footer: { Text("share.calendar.link.accessSummary") }
            }
            Section("share.calendar.confirmed") {
                Text(profile.name).font(.headline)
                SharingScopeSummary(channel: .calendarAccount, range: profile.range,
                                    sourceCount: profile.sourceCalendarIDs.count, content: profile.privacyMode,
                                    contentTitle: "sharing.defaultVisibility")
                SharedCalendarStatusView(profile: profile)
                if hasDraft {
                    Label("share.calendar.hasDraft", systemImage: "pencil.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("share.calendar.draftNotice")
                }
            }
            Section {
                if !manager.inventoryIsAvailable {
                    Text("share.calendar.link.unavailable").foregroundStyle(.secondary)
                } else if !hasTarget {
                    Text("share.calendar.link.missingTarget").foregroundStyle(.secondary)
                }
                if savedURL == nil || isChangingLink {
                    Text(savedURL == nil ? LocalizedStringKey("share.calendar.link.import.help") : LocalizedStringKey("share.calendar.link.change.help"))
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("share.calendar.link.placeholder", text: $input, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isEditingLink)
                        .disabled(!hasTarget || loadedBinding != bindingKey)
                        .accessibilityIdentifier("share.calendar.link.input")
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            if let text = strings.first { input = text }
                        }
                        .disabled(!hasTarget || loadedBinding != bindingKey)
                        .accessibilityIdentifier("share.calendar.link.paste")
                        Spacer()
                        Button("share.calendar.link.save", action: saveLink)
                            .disabled(!hasTarget || loadedBinding != bindingKey || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store == nil)
                            .accessibilityIdentifier("share.calendar.link.save")
                    }
                    if savedURL != nil {
                        Button("share.calendar.link.cancelEdit") {
                            input = savedURL?.absoluteString ?? ""
                            isChangingLink = false
                            isEditingLink = false
                        }
                        .accessibilityIdentifier("share.calendar.link.cancelEdit")
                    }
                } else if let savedURL {
                    Text(savedURL.absoluteString)
                        .font(.subheadline)
                        .accessibilityIdentifier("share.calendar.link.savedURL")
                    Button("share.calendar.link.change") {
                        input = savedURL.absoluteString
                        isChangingLink = true
                        isEditingLink = true
                    }
                    .disabled(!hasTarget || loadedBinding != bindingKey)
                    .accessibilityIdentifier("share.calendar.link.change")
                }
                Button("share.calendar.guide") { showingGuide = true }
                    .accessibilityIdentifier("share.calendar.guide")
                DisclosureGroup("share.calendar.link.privacy.title") {
                    Text("share.calendar.link.privacy.help")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("share.calendar.link.privacy")
                }
                .accessibilityIdentifier("share.calendar.link.accessDetails")
            } header: {
                Text(savedURL == nil ? LocalizedStringKey("share.calendar.link.import.title") : LocalizedStringKey("share.calendar.link.management"))
            } footer: {
                Text("share.calendar.link.unverified")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("share.calendar.title")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("common.done") { isEditingLink = false }
                    .accessibilityIdentifier("share.calendar.keyboard.done")
            }
        }
        .task(id: bindingKey) {
            loadedBinding = nil
            savedURL = nil
            input = ""
            isChangingLink = false
            isEditingLink = false
            await manager.refreshInventory()
            guard !Task.isCancelled else { return }
            loadLink()
        }
        .sheet(isPresented: $showingGuide) {
            NavigationStack { SharedCalendarGuideView(calendarName: EventKitCalendarStore.namePrefix + profile.name) }
        }
        .alert("sharing.error.title", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("common.done") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func loadLink() {
        savedURL = nil
        loadedBinding = nil
        input = ""
        isChangingLink = false
        do {
            if store == nil {
                if let suppliedStore {
                    store = suppliedStore
                } else {
                    #if DEBUG
                    if manager.isUsingPreviewFixtures { store = SubscriptionLinkStore.preview }
                    else { store = try SubscriptionLinkStore() }
                    #else
                    store = try SubscriptionLinkStore()
                    #endif
                }
            }
            savedURL = try store?.link(for: profile)
            input = savedURL?.absoluteString ?? ""
            loadedBinding = bindingKey
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveLink() {
        do {
            guard hasTarget, loadedBinding == bindingKey else { throw SubscriptionLinkError.missingTarget }
            guard let store else { throw SubscriptionLinkError.storageUnavailable }
            let url = try store.save(input, for: profile)
            savedURL = url
            input = url.absoluteString
            loadedBinding = bindingKey
            isChangingLink = false
            isEditingLink = false
        } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
struct CalendarSharingHub: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    let profiles: [SharedCalendarProfile]
    let candidateSourceIDs: Set<String>
    let candidateRange: SharedCalendarRange
    let onSelect: (SharedCalendarProfile) -> Void
    let onCreate: () -> Void

    private var availableProfiles: [SharedCalendarProfile] { profiles.filter { !$0.pendingDeletion } }

    var body: some View {
        List {
            if cloud.session != nil, cloud.isBusy {
                Section { ProgressView("sharing.hub.loading") }
            }
            if cloud.session != nil, let error = cloud.errorMessage {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("common.retry") { Task { await cloud.refresh() } }
                }
            }
            if !availableProfiles.isEmpty {
                Section {
                    ForEach(availableProfiles) { profile in
                    Button { onSelect(profile) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(profile.name).foregroundStyle(.primary)
                            SharedRangeSummary(range: profile.range).foregroundStyle(.secondary)
                            SharedCalendarStatusView(profile: profile)
                        }
                    }
                    .accessibilityIdentifier("share.calendar.profile.\(profile.name)")
                }
                } header: { SharingChannelLabel(channel: .calendarAccount) }
            }
            if cloud.session != nil, !cloud.sources.isEmpty {
                Section {
                    ForEach(cloud.sources) { source in
                        NavigationLink {
                            CloudSourceSharingView(sourceID: source.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.name)
                                CloudSharingSourceSubtitle(source: source)
                            }
                        }
                        .accessibilityIdentifier("share.calendar.cloud.profile.\(source.id.uuidString)")
                    }
                } header: { SharingChannelLabel(channel: .cloud) }
            }
            if availableProfiles.isEmpty && (cloud.session == nil || cloud.sources.isEmpty) {
                Section {
                    Text("sharing.hub.empty").foregroundStyle(.secondary)
                }
            }
            Section {
                Button(action: onCreate) {
                    VStack(alignment: .leading, spacing: 5) {
                        SharingChannelLabel(channel: .calendarAccount)
                        Text("sharing.hub.account.help").font(.caption).foregroundStyle(.secondary)
                    }
                }
                    .accessibilityIdentifier("share.calendar.create")
                NavigationLink {
                    CloudCalendarSharingView(candidateSourceIDs: candidateSourceIDs, candidateRange: candidateRange,
                                             startsWithNewSource: true)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        SharingChannelLabel(channel: .cloud)
                        Text("sharing.hub.cloud.help").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("share.calendar.cloud.open")
            } header: { Text("sharing.hub.new") }
            footer: { Text("sharing.hub.scope.help") }
        }
        .navigationTitle("sharing.hub.title")
        .task {
            if cloud.session != nil { await cloud.refresh() }
        }
    }
}
