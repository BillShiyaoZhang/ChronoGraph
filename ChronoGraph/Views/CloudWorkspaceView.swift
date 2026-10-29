import SwiftUI
import AuthenticationServices

struct CloudWorkspaceView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var inviteCode = ""
    @State private var registrationName = ""
    @State private var registering = false
    @FocusState private var authFocus: AuthField?
    private enum AuthField: Hashable { case username, password, confirmation, invite, name, server, nickname, incoming }
    @State private var showingFind = false

    var body: some View {
        Form {
            Section {
                Text(CloudCopy.text("云端协作 · 测试版")).font(.headline)
                Text(CloudCopy.text("在所选服务器保存你明确启用的忙闲数据、分享权限和邀约。原有本机查看、图片导出和 iCloud 共享继续独立使用。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            // Connection errors and local sign-out progress must remain visible before long authentication forms.
            CloudStatusSections()
            if cloud.session == nil { connectionSection; passwordSection }
            else { collaborationSections }
        }
        .id((cloud.session?.user.id.uuidString ?? "signed-out") + locale.identifier)
        .accessibilityIdentifier("cloud.workspace.form")
        .navigationTitle(CloudCopy.text("云端协作"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(CloudCopy.text("完成")) { authFocus = nil }.accessibilityIdentifier("cloud.auth.keyboard.done")
            }
        }
        .task {
            server = cloud.endpoint
            if cloud.session != nil { await cloud.refresh(); await cloud.refreshInvitations() }
            else if cloud.appleSignInAvailable && !server.isEmpty { await cloud.prepareSignIn() }
        }
        .refreshable { if cloud.session != nil { await cloud.refresh(); await cloud.refreshInvitations() } }
        .onChange(of: cloud.session?.user.id) { _, value in if value != nil { clearSecrets(); registering = false } }
        .onDisappear { clearSecrets() }
        .sheet(isPresented: $showingFind) { NavigationStack { CloudFindTimeView() } }
    }

    private var connectionSection: some View {
        Section {
            TextField(CloudCopy.text("HTTPS 服务器地址"), text: $server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .focused($authFocus, equals: .server).submitLabel(.done).onSubmit { authFocus = nil }.accessibilityIdentifier("cloud.server")
            Button(CloudCopy.text("保存服务器")) { Task { await cloud.configure(server) } }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.configure")
            if cloud.appleSignInAvailable && cloud.challenge != nil {
                SignInWithAppleButton(.signIn, onRequest: cloud.configureAppleRequest) { result in
                    Task { await cloud.completeAppleSignIn(result) }
                }.frame(height: 48).disabled(cloud.isBusy)
            }
        } header: { Text(CloudCopy.text("连接你的服务器")) }
        footer: { Text(CloudCopy.text("登录不等于上传授权。添加日历时会再次展示上传范围。")) }
    }
    private var passwordSection: some View {
        Section {
            TextField(CloudCopy.text("用户名"), text: $username)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.asciiCapable).submitLabel(.next).focused($authFocus, equals: .username)
                .onSubmit { authFocus = .password }.accessibilityIdentifier("cloud.auth.username")
            SecureField(registering ? CloudCopy.text("设置密码（至少12个字符）") : CloudCopy.text("密码"), text: $password)
                .textContentType(registering ? .newPassword : .password)
                .submitLabel(registering ? .next : .go).focused($authFocus, equals: .password)
                .onSubmit { if registering { authFocus = .confirmation } else { submitPassword() } }
                .accessibilityIdentifier("cloud.auth.password")
                .id(registering ? "registration-password" : "login-password")
            if registering {
                SecureField(CloudCopy.text("再次输入密码"), text: $confirmation).textContentType(.newPassword)
                    .submitLabel(.next).focused($authFocus, equals: .confirmation)
                    .onSubmit { authFocus = .invite }.accessibilityIdentifier("cloud.auth.confirmation")
                TextField(CloudCopy.text("邀请码"), text: $inviteCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.next).focused($authFocus, equals: .invite)
                    .onSubmit { authFocus = .name }.accessibilityIdentifier("cloud.auth.invite")
                TextField(CloudCopy.text("昵称（可选）"), text: $registrationName).textContentType(.nickname)
                    .submitLabel(.go).focused($authFocus, equals: .name)
                    .onSubmit { submitPassword() }.accessibilityIdentifier("cloud.auth.displayName")
                Text(CloudCopy.text("用户名为3至32位英文字母、数字、点、下划线或短横线。密码为12至128个字符，区分大小写并保留空格。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button(registering ? CloudCopy.text("注册并登录") : CloudCopy.text("登录")) { submitPassword() }
                .disabled(cloud.isBusy || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.isEmpty || password.isEmpty)
                .accessibilityIdentifier(registering ? "cloud.password.register" : "cloud.password.login")
            Button(registering ? CloudCopy.text("已有账号？登录") : CloudCopy.text("有邀请码？创建账号")) {
                clearSecrets(); registering.toggle(); cloud.errorMessage = nil; cloud.notice = nil; authFocus = .username
            }.disabled(cloud.isBusy).accessibilityIdentifier(registering ? "cloud.auth.showLogin" : "cloud.auth.showRegister")
        } header: { Text(registering ? CloudCopy.text("邀请码注册") : CloudCopy.text("账号密码登录")) }
        footer: { Text(CloudCopy.text("账号仅用于当前服务器。忘记密码请联系管理员重置。登录后仍需单独选择允许上传的日历。")) }
    }
    private func clearSecrets() { password = ""; confirmation = ""; inviteCode = "" }
    private func submitPassword() {
        guard !cloud.isBusy else { return }
        guard !registering || CloudPasswordPolicy.matches(password, confirmation) else {
            cloud.errorMessage = CloudCopy.error(CloudClientError.passwordMismatch); return
        }
        let submittedPassword = password, submittedUsername = username, submittedName = registrationName, submittedServer = server
        let submittedInvite = registering ? inviteCode : nil
        authFocus = nil; cloud.errorMessage = nil
        Task {
            if submittedServer != cloud.endpoint { await cloud.configure(submittedServer) }
            guard cloud.errorMessage == nil else { clearSecrets(); return }
            let signedIn = await cloud.passwordSignIn(username: submittedUsername, password: submittedPassword, inviteCode: submittedInvite, displayName: submittedName)
            // An invitation typo should only require correcting the invitation. Keep
            // the registration draft in memory until success or leaving this screen.
            if signedIn || submittedInvite == nil { clearSecrets() }
        }
    }
    @ViewBuilder private var collaborationSections: some View {
        Section {
            Button(CloudCopy.text("找时间")) { showingFind = true }
                .disabled(cloud.isBusy || cloud.sources.isEmpty || cloud.sharedSources.isEmpty)
                .accessibilityIdentifier("cloud.find.open")
            if cloud.sources.isEmpty || cloud.sharedSources.isEmpty {
                Text(CloudCopy.text("先上传自己的日历，并接收至少一位参与者分享的日历，即可查找共同时间。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        CloudInvitationSections()
        Section(CloudCopy.text("日历与账号")) {
            NavigationLink { CloudUploadedCalendarsView() } label: { Label(CloudCopy.text("我上传的日历"), systemImage: "icloud.and.arrow.up") }
                .accessibilityIdentifier("cloud.uploads.open")
            NavigationLink { CloudReceivedCalendarsView() } label: { Label(CloudCopy.text("收到的日历"), systemImage: "person.2") }
                .accessibilityIdentifier("cloud.received.open")
            NavigationLink { CloudAccountView() } label: { Label(CloudCopy.text("账号与服务器"), systemImage: "person.crop.circle") }
                .accessibilityIdentifier("cloud.account.open")
        }
        Section {
            Button(CloudCopy.text("刷新云端状态")) { Task { await cloud.refresh() } }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.refresh")
        }
    }
}

/// Shared by pushed pages so asynchronous failures remain visible at the action's location.
private struct CloudStatusSections: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    var body: some View {
        if cloud.isBusy { Section { ProgressView(CloudCopy.text("正在处理…")) } }
        if let error = cloud.errorMessage { Section { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("cloud.error") } }
        if let notice = cloud.notice { Section { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("cloud.notice") } }
        if let status = cloud.calendarSyncStatus { Section { Text(status).font(.footnote).foregroundStyle(.secondary) } }
    }
}

struct CloudReceivedCalendarsView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var incomingToken = ""
    @FocusState private var inputFocused: Bool
    var body: some View {
        Form {
            Section(CloudCopy.text("收到的日历")) {
                if cloud.sharedSources.isEmpty { Text(CloudCopy.text("还没有收到的日历。粘贴对方的站内添加链接即可接收。")) .foregroundStyle(.secondary) }
                ForEach(cloud.sharedSources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.ownerName + " · " + source.name)
                        Text(source.privacy.label).font(.caption).foregroundStyle(.secondary)
                        Text(source.lastSyncedAt.map { CloudCopy.format("来源更新时间：%@", $0.formatted(date: .abbreviated, time: .shortened)) } ?? CloudCopy.text("来源尚未同步"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                TextField(CloudCopy.text("粘贴添加链接或令牌"), text: $incomingToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($inputFocused).submitLabel(.done).onSubmit { inputFocused = false }.accessibilityIdentifier("cloud.incoming.token")
                Button(CloudCopy.text("接收分享的日历")) { inputFocused = false; Task { await cloud.redeem(incomingToken); if cloud.errorMessage == nil { incomingToken = "" } } }
                    .disabled(cloud.isBusy || incomingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("cloud.incoming.add")
            } footer: { Text(CloudCopy.text("接收后，可在首页的“选择显示的日历”中勾选查看。这里只管理接收关系，不改变首页的显示选择。")) }
            CloudStatusSections()
        }
        .id(locale.identifier)
        .navigationTitle(CloudCopy.text("收到的日历")).navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(CloudCopy.text("完成")) { inputFocused = false } } }
        .refreshable { await cloud.refresh() }
        .task { await cloud.refresh() }
        .onChange(of: cloud.session == nil) { _, signedOut in if signedOut { dismiss() } }
    }
}

private struct CloudAccountView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var nickname = ""
    @State private var showingPasswordChange = false
    @State private var confirmsAccountDeletion = false
    @State private var showingAccessibleDeletionReview = false
    @FocusState private var nicknameFocused: Bool
    var body: some View {
        Form {
            Section(CloudCopy.text("账号")) {
                TextField(CloudCopy.text("对外显示昵称"), text: $nickname).focused($nicknameFocused).submitLabel(.done).onSubmit { nicknameFocused = false }
                    .accessibilityIdentifier("cloud.nickname")
                Button(CloudCopy.text("保存昵称")) { nicknameFocused = false; Task { await cloud.updateDisplayName(nickname) } }
                    .disabled(cloud.isBusy || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nickname.unicodeScalars.count > 100)
                    .accessibilityIdentifier("cloud.nickname.save")
                if let id = cloud.currentUserID { LabeledContent(CloudCopy.text("我的账号编号")) { Text(id.uuidString).font(.caption).textSelection(.enabled) } }
                if cloud.session?.usesPassword == true {
                    LabeledContent(CloudCopy.text("登录方式"), value: CloudCopy.text("账号密码"))
                    Button(CloudCopy.text("修改密码")) { cloud.errorMessage = nil; showingPasswordChange = true }
                        .disabled(cloud.isBusy).accessibilityIdentifier("cloud.password.change.open")
                }
            }
            Section(CloudCopy.text("服务器")) {
                Text(cloud.endpoint).textSelection(.enabled).font(.footnote)
                Text(CloudCopy.text("账号与上传授权仅适用于此服务器。更换服务器前，请先退出此设备。")) .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(CloudCopy.text("退出此设备"), role: .destructive) { Task { await cloud.signOut() } }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.logout")
                Button(CloudCopy.text("删除云端账号"), role: .destructive) {
                    if dynamicTypeSize.isAccessibilitySize { showingAccessibleDeletionReview = true }
                    else { confirmsAccountDeletion = true }
                }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.account.delete")
            }
            CloudStatusSections()
        }
        .accessibilityIdentifier("cloud.account.form")
        .navigationTitle(CloudCopy.text("账号与服务器")).navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(CloudCopy.text("完成")) { nicknameFocused = false }.accessibilityIdentifier("cloud.auth.keyboard.done") } }
        .task { nickname = cloud.session?.user.displayName ?? "" }
        .onChange(of: cloud.session?.user.displayName) { _, value in nickname = value ?? "" }
        .onChange(of: cloud.session == nil) { _, signedOut in if signedOut { dismiss() } }
        .sheet(isPresented: $showingPasswordChange) { NavigationStack { CloudPasswordChangeView() } }
        .confirmationDialog(CloudCopy.text("删除云端账号？"), isPresented: $confirmsAccountDeletion, titleVisibility: .visible) {
            Button(CloudCopy.text("删除账号及云端数据"), role: .destructive) { Task { await cloud.deleteAccount() } }.accessibilityIdentifier("cloud.account.delete.confirm")
            Button(CloudCopy.text("取消"), role: .cancel) {}.accessibilityIdentifier("cloud.account.delete.cancel")
        } message: { Text(CloudAccountDeletionPresentation.disclosure) }
        .sheet(isPresented: $showingAccessibleDeletionReview) { CloudAccessibleAccountDeletionReview() }
    }
}

/// Reusable server-sharing route used by the home share hub and cloud management.
struct CloudCalendarSharingView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let candidateSourceIDs: Set<String>
    let candidateRange: SharedCalendarRange?
    let startsWithNewSource: Bool
    @State private var showingNewSource = false
    @State private var didStartNewSource = false
    @State private var completedSourceID: UUID?

    init(candidateSourceIDs: Set<String> = [], candidateRange: SharedCalendarRange? = nil, startsWithNewSource: Bool = false) {
        self.candidateSourceIDs = candidateSourceIDs
        self.candidateRange = candidateRange
        self.startsWithNewSource = startsWithNewSource
    }
    var body: some View {
        Group {
            if cloud.session == nil { CloudWorkspaceView() }
            else {
                Form {
                    Section {
                        SharingChannelLabel(channel: .cloud)
                        Text(CloudCopy.text("选择已上传的日历继续分享，或新建上传来源。已有来源沿用已确认的上传设置。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section(CloudCopy.text("已上传的日历")) {
                        ForEach(cloud.sources) { source in
                            NavigationLink { CloudSourceSharingView(sourceID: source.id) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(source.name)
                                    CloudSharingSourceSubtitle(source: source)
                                }
                            }.accessibilityIdentifier("cloud.sharing.source.\(source.id.uuidString)")
                        }
                        CloudPendingSharingRows { completedSourceID = $0.id }
                        Button(CloudCopy.text("新建上传来源")) { showingNewSource = true }
                            .disabled(cloud.isBusy).accessibilityIdentifier("cloud.sharing.new")
                    }
                    CloudStatusSections()
                }
                .navigationTitle(CloudCopy.text("通过服务器共享")).navigationBarTitleDisplayMode(.inline)
            }
        }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(CloudCopy.text("关闭")) { dismiss() }.accessibilityIdentifier("cloud.sharing.close") } }
        .task {
            if cloud.session != nil, !cloud.isBusy { await cloud.refresh() }
            startNewSourceIfNeeded()
        }
        .onChange(of: cloud.session?.user.id) { _, _ in startNewSourceIfNeeded() }
        .onChange(of: cloud.isBusy) { _, busy in if !busy { startNewSourceIfNeeded() } }
        .sheet(isPresented: $showingNewSource) {
            NavigationStack {
                CloudUploadScopeEditor(candidateSourceIDs: candidateSourceIDs, candidateRange: candidateRange) { source in
                    completedSourceID = source.id
                }
            }
        }
        .navigationDestination(isPresented: Binding(get: { completedSourceID != nil }, set: { if !$0 { completedSourceID = nil } })) {
            if let completedSourceID { CloudSourceSharingView(sourceID: completedSourceID) }
        }
    }
    private func startNewSourceIfNeeded() {
        guard startsWithNewSource, !didStartNewSource, cloud.session != nil, !cloud.isBusy else { return }
        didStartNewSource = true
        guard !cloud.pendingSharingDrafts.contains(where: { pending in !cloud.sources.contains { $0.id == pending.id } }) else { return }
        showingNewSource = true
    }
}

private struct CloudPendingSharingRows: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    var onConfirmed: ((CloudSource) -> Void)? = nil
    private var pending: [CloudSharingDraft] {
        cloud.pendingSharingDrafts.filter { draft in !cloud.sources.contains { $0.id == draft.id } }
    }
    var body: some View {
        ForEach(pending) { draft in
            NavigationLink {
                CloudUploadScopeEditor(sourceID: draft.id, onConfirmed: onConfirmed)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.name)
                    Text("cloud.sharing.pending.resume").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("cloud.sharing.pending.\(draft.id.uuidString)")
        }
    }
}

/// An already selected cloud source goes directly to its sharing methods.
struct CloudSourceSharingView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID
    @State private var linkKind: CloudLinkKind?
    @State private var showingScope = false
    private var source: CloudSource? { cloud.sources.first { $0.id == sourceID } }
    var body: some View {
        Form {
            if let source {
                CloudSharingLinkSection(source: source, linkKind: $linkKind)
                if source.deviceId == cloud.session?.deviceId, cloud.bindings.contains(where: { $0.sourceId == sourceID }) {
                    Section {
                        Button(CloudCopy.text("修改上传设置")) { showingScope = true }
                            .disabled(cloud.isBusy).accessibilityIdentifier("cloud.source.level.edit")
                    }
                }
            }
            CloudStatusSections()
        }
        .navigationTitle(source?.name ?? CloudCopy.text("分享日历")).navigationBarTitleDisplayMode(.inline)
        .sheet(item: $linkKind) { kind in if let source { NavigationStack { CloudLinkCreationView(source: source, kind: kind) } } }
        .sheet(isPresented: $showingScope) { if let source { NavigationStack { CloudUploadScopeEditor(source: source) } } }
        .onChange(of: source == nil || cloud.session == nil) { _, missing in if missing { dismiss() } }
    }
}

private struct CloudSharingLinkSection: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    let source: CloudSource
    @Binding var linkKind: CloudLinkKind?
    private var binding: CloudLocalBinding? { cloud.bindings.first { $0.sourceId == source.id } }
    private var isReady: Bool { binding?.hasPendingScope != true && source.coverageStart != nil && source.coverageEnd != nil }
    private var range: SharedCalendarRange? {
        if let binding { return binding.sharing?.range ?? binding.confirmedRange }
        guard let start = source.coverageStart, let end = source.coverageEnd else { return nil }
        return .fixed(start: start, endExclusive: end)
    }
    private var configuration: CloudSharingDraft? { binding?.sharing }
    private var sourceCount: Int { configuration?.calendarIDs.count ?? binding.map { ($0.calendarIds ?? [$0.calendarId]).count } ?? 1 }
    var body: some View {
        Section(CloudCopy.text("分享链接")) {
            Text("cloud.sharing.links.rules").font(.footnote).foregroundStyle(.secondary)
            if binding?.hasPendingScope == true {
                Text(CloudCopy.text("新上传设置尚未成功更新。旧日期或字段的云端内容可能仍可访问；请先重试已确认的设置，再创建新链接。"))
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("cloud.upload.range.pending")
            } else if !isReady {
                Text(CloudCopy.text("此来源尚未成功上传。请先在上传设置中完成上传，再创建分享链接。")) .font(.footnote).foregroundStyle(.secondary)
            }
            Button(CloudCopy.text("创建站内添加链接")) { linkKind = .pairing }.disabled(cloud.isBusy || !isReady).accessibilityIdentifier("cloud.source.share")
            Button(CloudCopy.text("创建公开 ICS 订阅")) { linkKind = .feed }.disabled(cloud.isBusy || !isReady).accessibilityIdentifier("cloud.source.feed")
            DisclosureGroup(CloudCopy.text("查看已确认的共享范围")) {
                if let range {
                    SharingScopeSummary(channel: .cloud, range: range, sourceCount: sourceCount,
                        content: configuration?.defaultVisibility.privacyMode ?? PrivacyMode(rawValue: source.uploadLevel.rawValue) ?? .opaque,
                        destination: cloud.endpoint, contentTitle: "cloud.sharing.defaultVisibility")
                } else { SharingChannelLabel(channel: .cloud) }
                if let start = source.coverageStart, let end = source.coverageEnd {
                    Text(CloudCopy.format("最近成功上传的时段：%@ 至 %@", start.formatted(date: .abbreviated, time: .shortened), end.formatted(date: .abbreviated, time: .shortened)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("cloud.sharing.review.maximumDetails", value: source.uploadLevel.label)
            }.accessibilityIdentifier("cloud.sharing.scope.details")
        }
    }

}

private struct CloudUploadedCalendarsView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingSources = false
    var body: some View {
        Form {
            Section {
                ForEach(cloud.sources) { source in
                    NavigationLink { CloudSourceDetailView(sourceID: source.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name).accessibilityIdentifier("cloud.source.name.\(source.id.uuidString)")
                            CloudSharingSourceSubtitle(source: source)
                            if cloud.isUploadPaused(source.id) { Text(CloudCopy.text("此设备已暂停上传")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.accessibilityIdentifier("cloud.source.open.\(source.id.uuidString)")
                }
                CloudPendingSharingRows()
                Button(CloudCopy.text("上传我的日历")) { showingSources = true }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.source.add")
                if !cloud.bindings.isEmpty {
                    Button(CloudCopy.text("立即上传已启用的日历")) { Task { await cloud.sync() } }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.sources.sync")
                }
            } footer: { Text(CloudCopy.text("仅上传明确启用的日历、日期与字段。首页勾选的显示日历不会改变上传范围。")) }
            CloudStatusSections()
        }
        .navigationTitle(CloudCopy.text("我上传的日历")).navigationBarTitleDisplayMode(.inline)
        .refreshable { await cloud.refresh() }
        .sheet(isPresented: $showingSources) { NavigationStack { CloudSourcePickerView() } }
        .onChange(of: cloud.session == nil) { _, signedOut in if signedOut { dismiss() } }
    }
}

private struct CloudSourceDetailView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID
    @State private var linkKind: CloudLinkKind?
    @State private var showingLevel = false
    @State private var confirmsPause = false
    @State private var confirmsResume = false
    @State private var confirmsRemoval = false
    private var source: CloudSource? { cloud.sources.first { $0.id == sourceID } }
    private var hasBinding: Bool { source?.deviceId == cloud.session?.deviceId && cloud.bindings.contains { $0.sourceId == sourceID } }
    var body: some View {
        Form {
            if let source {
                Section(CloudCopy.text("上传与状态")) {
                    LabeledContent("cloud.sharing.review.maximumDetails", value: source.uploadLevel.label)
                    Text(source.lastSyncedAt.map { CloudCopy.format("最后上传：%@", $0.formatted(date: .abbreviated, time: .shortened)) } ?? CloudCopy.text("尚未上传日程"))
                        .font(.footnote).foregroundStyle(.secondary)
                    if let start = source.coverageStart, let end = source.coverageEnd {
                        Text(CloudCopy.format("已上传时段：%@ 至 %@", start.formatted(date: .abbreviated, time: .shortened), end.formatted(date: .abbreviated, time: .shortened)))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let binding = cloud.bindings.first(where: { $0.sourceId == sourceID }) {
                        LabeledContent("cloud.sharing.sources", value: (binding.sharing?.calendarIDs ?? binding.calendarIds ?? [binding.calendarId]).count.formatted())
                        if let configuration = binding.sharing {
                            LabeledContent("cloud.sharing.defaultVisibility") { Text(configuration.defaultVisibility.localizedKey) }
                        }
                        SharedRangeSummary(range: binding.confirmedRange)
                        if binding.hasPendingScope {
                            Text(CloudCopy.text("新上传设置尚未成功更新。旧日期或字段的云端内容可能仍可访问；请先重试已确认的设置，再创建新链接。"))
                                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("cloud.upload.range.pending")
                            if let pending = binding.pendingSharing {
                                DisclosureGroup("cloud.sharing.pending.status") {
                                    SharingScopeSummary(channel: .cloud, range: pending.range, sourceCount: binding.effectiveCalendarIDs.count,
                                        content: pending.defaultVisibility.privacyMode ?? .opaque,
                                        destination: cloud.endpoint, contentTitle: "cloud.sharing.defaultVisibility")
                                }
                            }
                        }
                    }
                    Text(CloudCopy.text("日期按已确认的固定或滚动范围上传。手机离线或暂停时，云端内容可能过旧。")) .font(.footnote).foregroundStyle(.secondary)
                    if hasBinding {
                        Button(CloudCopy.text("修改上传设置")) { showingLevel = true }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.source.level.edit")
                        if cloud.isUploadPaused(sourceID) {
                            Text(CloudCopy.text("此设备已暂停上传")).foregroundStyle(.secondary)
                            Button(CloudCopy.text("恢复此设备上传")) { confirmsResume = true }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.source.resume")
                        } else {
                            Button(CloudCopy.text("暂停此设备上传")) { confirmsPause = true }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.source.pause")
                        }
                    } else if source.deviceId == cloud.session?.deviceId {
                        Text(CloudCopy.text("此来源尚未关联到本机日历。若无法恢复原上传设置，可删除这份云端来源后重新创建。")) .font(.footnote).foregroundStyle(.secondary)
                    } else { Text(CloudCopy.text("此来源由其他设备上传。请在原设备管理上传设置。")) .font(.footnote).foregroundStyle(.secondary) }
                }
                CloudSharingLinkSection(source: source, linkKind: $linkKind)
                Section(CloudCopy.text("访问授权")) {
                    NavigationLink(CloudCopy.text("管理已发出的授权")) { CloudSourceAccessView(source: source) }.accessibilityIdentifier("cloud.source.access.\(source.id.uuidString)")
                }
                Section {
                    Button(CloudCopy.text("删除云端来源"), role: .destructive) { confirmsRemoval = true }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.source.delete")
                } footer: { Text(CloudCopy.text("暂停上传保留云端内容和分享权限。要停止别人后续访问，请撤销授权或删除云端来源。")) }
            }
            CloudStatusSections()
        }
        .navigationTitle(source?.name ?? CloudCopy.text("云端日历")).navigationBarTitleDisplayMode(.inline)
        .onChange(of: source == nil || cloud.session == nil) { _, missing in if missing { dismiss() } }
        .sheet(item: $linkKind) { kind in if let source { NavigationStack { CloudLinkCreationView(source: source, kind: kind) } } }
        .sheet(isPresented: $showingLevel) { if let source { NavigationStack { CloudUploadLevelView(source: source) } } }
        .confirmationDialog(CloudCopy.text("暂停此设备上传？"), isPresented: $confirmsPause, titleVisibility: .visible) {
            Button(CloudCopy.text("确认暂停")) { Task { await cloud.setUploadPaused(sourceID, paused: true) } }.accessibilityIdentifier("cloud.source.pause.confirm")
            Button(CloudCopy.text("取消"), role: .cancel) {}.accessibilityIdentifier("cloud.source.pause.cancel")
        } message: { Text(CloudCopy.text("已有云端数据、公开订阅和已发出的授权继续保留。暂停只停止这台设备后续上传，不会撤销他人的访问。")) }
        .confirmationDialog(CloudCopy.text("恢复此设备上传？"), isPresented: $confirmsResume, titleVisibility: .visible) {
            Button(CloudCopy.text("同意并恢复上传")) { Task { await cloud.setUploadPaused(sourceID, paused: false) } }.accessibilityIdentifier("cloud.source.resume.confirm")
            Button(CloudCopy.text("取消"), role: .cancel) {}.accessibilityIdentifier("cloud.source.resume.cancel")
        } message: { Text(CloudCopy.format("将向 %@ 按已确认的日历、日期与字段恢复上传，并持续更新。", cloud.endpoint)) }
        .confirmationDialog(CloudCopy.text("删除云端来源？"), isPresented: $confirmsRemoval, titleVisibility: .visible) {
            if let source { Button(CloudCopy.text("删除云端来源"), role: .destructive) { Task { await cloud.removeSource(source) } }.accessibilityIdentifier("cloud.source.delete.confirm") }
            Button(CloudCopy.text("取消"), role: .cancel) {}.accessibilityIdentifier("cloud.source.delete.cancel")
        } message: { Text(CloudCopy.text("停止上传并删除此来源的云端数据和分享。不会删除系统日历中的原始日程，已下载的内容不能追回。")) }
    }
}

private enum CloudLinkKind: String, Identifiable {
    case pairing, feed
    var id: String { rawValue }
}

private struct CloudLinkCreationView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var source: CloudSource
    let kind: CloudLinkKind
    @State private var pairing: CloudShareLink?
    @State private var feed: CloudFeedLink?
    init(source: CloudSource, kind: CloudLinkKind) {
        _source = State(initialValue: source)
        self.kind = kind
    }
    private var reviewRange: SharedCalendarRange? {
        if let binding = cloud.bindings.first(where: { $0.sourceId == source.id }) { return binding.sharing?.range ?? binding.confirmedRange }
        guard let start = source.coverageStart, let end = source.coverageEnd else { return nil }
        return .fixed(start: start, endExclusive: end)
    }
    private var configuration: CloudSharingDraft? { cloud.bindings.first(where: { $0.sourceId == source.id })?.sharing }
    var body: some View {
        Form {
            Section {
                Text(source.name).font(.headline)
                if let reviewRange {
                    SharingScopeSummary(channel: .cloud, range: reviewRange, sourceCount: configuration?.calendarIDs.count ?? 1,
                        content: configuration?.defaultVisibility.privacyMode ?? PrivacyMode(rawValue: source.uploadLevel.rawValue) ?? .opaque,
                        destination: cloud.endpoint, contentTitle: "cloud.sharing.defaultVisibility")
                }
                LabeledContent("cloud.sharing.review.maximumDetails", value: source.uploadLevel.label)
                Text("cloud.sharing.links.rules").font(.footnote).foregroundStyle(.secondary)
                if kind == .pairing {
                    Text(CloudCopy.text("收到链接的人可以登录同一服务器并添加你允许分享的日历。请只发送给愿意授权的人。")) .font(.footnote)
                } else {
                    Text(CloudCopy.text("任何持有此链接的人都可读取允许分享的内容，并可转发链接。已下载的副本不能追回。")) .font(.footnote)
                }
            }
            Section {
                if let pairing {
                    ShareLink(item: pairing.joinUrl) { Label(CloudCopy.text("分享添加链接"), systemImage: "square.and.arrow.up") }.accessibilityIdentifier("cloud.link.share")
                    Text(pairing.joinUrl.absoluteString).font(.footnote).textSelection(.enabled)
                    Text(CloudCopy.format("到期：%@", pairing.expiresAt.formatted(date: .abbreviated, time: .shortened)))
                } else if let feed {
                    ShareLink(item: feed.url) { Label(CloudCopy.text("发送订阅链接"), systemImage: "link") }.accessibilityIdentifier("cloud.feed.share")
                    Text(feed.url.absoluteString).font(.footnote).textSelection(.enabled)
                    Button(CloudCopy.text("撤销此订阅链接"), role: .destructive) {
                        Task { await cloud.revokeFeed(feed); if cloud.errorMessage == nil { dismiss() } }
                    }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.feed.revoke")
                } else {
                    Button(CloudCopy.text("确认字段并创建链接")) {
                        Task {
                            if kind == .pairing { pairing = await cloud.createShareLink(source) }
                            else { feed = await cloud.createFeedLink(source) }
                        }
                    }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.link.create")
                }
            }
            CloudStatusSections()
        }
        .navigationTitle(kind == .pairing ? CloudCopy.text("分享日历") : CloudCopy.text("公开订阅链接"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(CloudCopy.text("完成")) { dismiss() } } }
        .onChange(of: cloud.session == nil) { _, signedOut in if signedOut { dismiss() } }
    }
}

private struct CloudUploadLevelView: View {
    let source: CloudSource
    var body: some View { CloudUploadScopeEditor(source: source) }
}

private struct CloudPasswordChangeView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @FocusState private var focused: Field?
    private enum Field: Hashable { case current, new, confirmation }
    var body: some View {
        Form {
            Section {
                SecureField(CloudCopy.text("当前密码"), text: $current).textContentType(.password)
                    .focused($focused, equals: .current).submitLabel(.next)
                    .onSubmit { focused = .new }.accessibilityIdentifier("cloud.password.current")
                SecureField(CloudCopy.text("新密码（至少12个字符）"), text: $new).textContentType(.newPassword)
                    .focused($focused, equals: .new).submitLabel(.next)
                    .onSubmit { focused = .confirmation }.accessibilityIdentifier("cloud.password.new")
                SecureField(CloudCopy.text("再次输入新密码"), text: $confirmation).textContentType(.newPassword)
                    .focused($focused, equals: .confirmation).submitLabel(.go)
                    .onSubmit { submit() }.accessibilityIdentifier("cloud.password.newConfirmation")
            } footer: { Text(CloudCopy.text("密码为12至128个字符。修改后其他设备需要重新登录，本机继续保持登录。")) }
            Section {
                Button(CloudCopy.text("保存新密码")) { submit() }.disabled(cloud.isBusy || current.isEmpty || new.isEmpty || confirmation.isEmpty)
                    .accessibilityIdentifier("cloud.password.change.save")
                if cloud.isBusy { ProgressView(CloudCopy.text("正在处理…")) }
            }
            if let error = cloud.errorMessage { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("cloud.password.change.error") } }
        }.navigationTitle(CloudCopy.text("修改密码")).navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(CloudCopy.text("取消")) { dismiss() }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.password.change.cancel") }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(CloudCopy.text("完成")) { focused = nil }.accessibilityIdentifier("cloud.auth.keyboard.done")
                }
            }
            .interactiveDismissDisabled(cloud.isBusy)
            .onDisappear { current = ""; new = ""; confirmation = "" }
            .onChange(of: cloud.session?.user.id) { _, value in if value == nil { dismiss() } }
    }
    private func submit() {
        guard !cloud.isBusy else { return }
        guard CloudPasswordPolicy.matches(new, confirmation) else { cloud.errorMessage = CloudCopy.error(CloudClientError.passwordMismatch); return }
        let old = current, replacement = new
        focused = nil
        Task {
            let changed = await cloud.changePassword(current: old, new: replacement)
            current = ""; new = ""; confirmation = ""
            if changed { dismiss() }
        }
    }
}

private enum CloudAccountDeletionPresentation {
    static var disclosure: String { CloudCopy.text("将删除此账号的云端来源、分享和登录会话，并取消关联的活跃约定。他人的协调历史中会保留匿名记录。本机和 iCloud 中的原始日历、已保存日程均保留，需在系统日历中自行处理。Apple 登录授权请单独管理。") }
}

/// Native confirmation popovers can clip their fixed footer at accessibility text sizes.
/// Keep the complete disclosure and destructive action in one scrollable review instead.
private struct CloudAccessibleAccountDeletionReview: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(CloudAccountDeletionPresentation.disclosure)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("cloud.account.delete.disclosure")
                }
                Section {
                    Button(CloudCopy.text("删除账号及云端数据"), role: .destructive) {
                        Task {
                            await cloud.deleteAccount()
                            if cloud.session == nil { dismiss() }
                        }
                    }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.account.delete.confirm")
                    if cloud.isBusy { ProgressView(CloudCopy.text("正在处理…")) }
                }
                if let error = cloud.errorMessage {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("cloud.account.delete.error") }
                }
            }
            .navigationTitle(CloudCopy.text("删除云端账号？"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(CloudCopy.text("取消")) { dismiss() }
                        .disabled(cloud.isBusy).accessibilityIdentifier("cloud.account.delete.cancel")
                }
            }
        }.interactiveDismissDisabled(cloud.isBusy)
    }
}

private func meetingStatus(_ status: String) -> String {
    switch status { case "confirmed": return CloudCopy.text("已定档"); case "cancelled": return CloudCopy.text("已取消"); default: return CloudCopy.text("等待回应") }
}
private func responseLabel(_ response: String) -> String {
    switch response { case "accepted": return CloudCopy.text("已同意"); case "declined": return CloudCopy.text("不方便"); case "tentative": return CloudCopy.text("待定"); default: return CloudCopy.text("待回应") }
}

struct CloudSourcePickerView: View {
    var body: some View { CloudUploadScopeEditor() }
}

struct CloudFindTimeView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPeople: Set<UUID> = []
    @State private var days = 7
    @State private var duration = 60
    @State private var dailyStart = "09:00"
    @State private var dailyEnd = "21:00"
    @State private var title = CloudCopy.text("约时间")
    @State private var selectedCandidate: CloudCandidate?
    private var people: [(id: UUID, name: String)] {
        Dictionary(grouping: cloud.sharedSources, by: \.ownerId).map { (id: $0.key, name: $0.value.first?.ownerName ?? CloudCopy.text("参与者")) }.sorted { $0.name < $1.name }
    }
    var body: some View {
        Form {
            Section(CloudCopy.text("参与者（我默认参加）")) {
                ForEach(people, id: \.id) { person in
                    Toggle(person.name, isOn: Binding(get: { selectedPeople.contains(person.id) }, set: { if $0 { selectedPeople.insert(person.id) } else { selectedPeople.remove(person.id) } })).accessibilityIdentifier("cloud.find.person.\(person.id.uuidString)")
                }
            }
            Section { Text(CloudCopy.text("找时间使用我上传的全部日历，以及所选参与者已分享给我的全部日历；与首页勾选的显示日历无关。")) .font(.footnote).foregroundStyle(.secondary) }
            Section(CloudCopy.text("查找条件")) {
                Picker(CloudCopy.text("日期"), selection: $days) { Text(CloudCopy.text("未来3天")).tag(3); Text(CloudCopy.text("未来7天")).tag(7); Text(CloudCopy.text("未来14天")).tag(14) }.accessibilityIdentifier("cloud.find.days")
                Picker(CloudCopy.text("时长"), selection: $duration) { Text(CloudCopy.text("30分钟")).tag(30); Text(CloudCopy.text("60分钟")).tag(60); Text(CloudCopy.text("90分钟")).tag(90) }.accessibilityIdentifier("cloud.find.duration")
                TextField(CloudCopy.text("每日开始 HH:mm"), text: $dailyStart).keyboardType(.numbersAndPunctuation)
                TextField(CloudCopy.text("每日结束 HH:mm"), text: $dailyEnd).keyboardType(.numbersAndPunctuation)
                Text(CloudCopy.format("时区：%@", TimeZone.current.identifier)).font(.caption).foregroundStyle(.secondary)
                Button(CloudCopy.text("查找共同候选")) { Task { await cloud.search(selectedPeople: selectedPeople, days: days, duration: duration, dailyStart: dailyStart, dailyEnd: dailyEnd) } }
                    .disabled(selectedPeople.isEmpty || cloud.isBusy).accessibilityIdentifier("cloud.find.search")
            }
            if let availability = cloud.availability {
                Section(CloudCopy.text("共同候选 · 待确认")) {
                    Text(CloudCopy.format("候选时区：%@", CloudDatePresentation.zoneIdentifier(availability.timezone)))
                    TextField(CloudCopy.text("邀约标题"), text: $title).accessibilityIdentifier("cloud.find.title")
                    if availability.windows.isEmpty { Text(CloudCopy.text("没有符合条件的时间。请缩短时长或调整日期、时段。")) }
                    ForEach(availability.windows) { candidate in
                        Button { selectedCandidate = candidate } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(CloudDatePresentation.dateAndTime(candidate.suggestedStart, timezone: availability.timezone))
                                Text(CloudCopy.format("至 %@", CloudDatePresentation.time(candidate.suggestedEnd, timezone: availability.timezone))).font(.caption)
                            }
                        }.accessibilityIdentifier("cloud.find.candidate")
                    }
                    Text(CloudCopy.text("基于最后上传的日程；未分享事项可能仍有冲突。创建邀约不会自动占用他人的系统日历。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if cloud.isBusy { ProgressView() }
            if let error = cloud.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("cloud.error") }
        }.accessibilityIdentifier("cloud.find.form")
            .navigationTitle(CloudCopy.text("找时间"))
            .onChange(of: cloud.session == nil) { _, signedOut in if signedOut { dismiss() } }
            .onChange(of: selectedPeople) { _, _ in cloud.invalidateCandidates() }
            .onChange(of: days) { _, _ in cloud.invalidateCandidates() }
            .onChange(of: duration) { _, _ in cloud.invalidateCandidates() }
            .onChange(of: dailyStart) { _, _ in cloud.invalidateCandidates() }
            .onChange(of: dailyEnd) { _, _ in cloud.invalidateCandidates() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(CloudCopy.text("完成")) { dismiss() } } }
            .confirmationDialog(CloudCopy.text("发起这个时间的邀约？"), isPresented: Binding(get: { selectedCandidate != nil }, set: { if !$0 { selectedCandidate = nil } })) {
                if let candidate = selectedCandidate {
                    Button(CloudCopy.text("发起邀约")) { Task { await cloud.propose(candidate, title: title); if cloud.errorMessage == nil { dismiss() }; selectedCandidate = nil } }.accessibilityIdentifier("cloud.find.propose")
                    ShareLink(item: CloudCopy.format("%@—%@（%@），方便吗？", CloudDatePresentation.dateAndTime(candidate.suggestedStart, timezone: cloud.availability?.timezone ?? TimeZone.current.identifier), CloudDatePresentation.time(candidate.suggestedEnd, timezone: cloud.availability?.timezone ?? TimeZone.current.identifier), cloud.availability?.timezone ?? TimeZone.current.identifier)) { Text(CloudCopy.text("分享候选时间")) }
                }
                Button(CloudCopy.text("取消"), role: .cancel) { selectedCandidate = nil }.accessibilityIdentifier("cloud.find.propose.cancel")
            }
    }
}

struct CloudMeetingDetailView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    @State private var calendarNotice: String?
    @State private var confirmsRemoval = false
    private let writer = CloudMeetingCalendarWriter()
    private var meeting: CloudMeeting? { cloud.meetings.first { $0.id == meetingID } }
    var body: some View {
        Form {
            CloudInvitationRefreshStatus()
            if let meeting {
                Section {
                    Text(meeting.title).font(.headline)
                    Text(CloudDatePresentation.dateAndTime(meeting.start, timezone: meeting.timezone)).accessibilityIdentifier("cloud.meeting.start")
                    Text(CloudCopy.format("至 %@ · %@", CloudDatePresentation.time(meeting.end, timezone: meeting.timezone), CloudDatePresentation.zoneIdentifier(meeting.timezone)))
                    (Text(LocalizedStringKey(meeting.invitationStatusKey(for: cloud.currentUserID)))
                     + Text(" · ") + Text(CloudCopy.format("第%d版", meeting.revision)))
                        .foregroundStyle(.secondary)
                }
                Section(CloudCopy.text("参与者")) {
                    ForEach(meeting.participants) { person in
                        VStack(alignment: .leading, spacing: 3) {
                            LabeledContent(cloud.displayName(for: person.userId)) {
                                Text(responseLabel(person.response)).accessibilityIdentifier("cloud.meeting.response.\(person.userId.uuidString)")
                            }
                            Text(person.userId.uuidString).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }.font(.subheadline)
                    }
                }
                if meeting.status == "proposed" {
                    Section {
                        if meeting.start <= Date() {
                            Text("invitations.expired.help").font(.footnote).foregroundStyle(.secondary)
                        }
                        Button(CloudCopy.text("同意这个版本")) { Task { await cloud.meetingAction(meeting, action: "response", response: "accepted") } }.accessibilityIdentifier("cloud.meeting.accept")
                            .disabled(meeting.start <= Date())
                        Button(CloudCopy.text("待定")) { Task { await cloud.meetingAction(meeting, action: "response", response: "tentative") } }.accessibilityIdentifier("cloud.meeting.tentative")
                            .disabled(meeting.start <= Date())
                        Button(CloudCopy.text("不方便")) { Task { await cloud.meetingAction(meeting, action: "response", response: "declined") } }.accessibilityIdentifier("cloud.meeting.decline")
                            .disabled(meeting.start <= Date())
                        if meeting.hostId == cloud.currentUserID {
                            Button(CloudCopy.text("全员同意后定档")) { Task { await cloud.meetingAction(meeting, action: "confirm") } }
                                .disabled(meeting.start <= Date() || !meeting.participants.allSatisfy { $0.response == "accepted" }).accessibilityIdentifier("cloud.meeting.confirm")
                            Button(CloudCopy.text("取消邀约"), role: .destructive) { Task { await cloud.meetingAction(meeting, action: "cancel") } }.accessibilityIdentifier("cloud.meeting.cancel")
                        }
                    }.disabled(cloud.isBusy)
                }
                if meeting.status == "confirmed" {
                    Section {
                        if meeting.hostId == cloud.currentUserID {
                            Button(CloudCopy.text("取消已定档约定"), role: .destructive) { Task { await cloud.meetingAction(meeting, action: "cancel") } }
                                .disabled(cloud.isBusy).accessibilityIdentifier("cloud.meeting.cancelConfirmed")
                        }
                        NavigationLink(CloudCopy.text("将约定存入系统日历")) { CloudMeetingCalendarView(meeting: meeting) }.accessibilityIdentifier("cloud.meeting.calendar")
                        Text(CloudCopy.text("App 内定档与写入系统日历是两种状态。请明确选择自己的可写日历。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
                if let meeting, meeting.status == "cancelled" {
                    Section {
                        Button(CloudCopy.text("移除此设备中由 App 创建的日程"), role: .destructive) { confirmsRemoval = true }
                        Text(CloudCopy.text("仅核对并移除 ChronoGraph 为此约定创建的日程；手动修改的日程需在系统日历处理。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            if let calendarNotice { Text(calendarNotice).foregroundStyle(.secondary) }
            if cloud.isBusy { ProgressView() }
            if let error = cloud.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("cloud.error") }
        }.accessibilityIdentifier("cloud.meeting.form")
            .navigationTitle(CloudCopy.text("邀约详情"))
            .task(id: cloud.homeDisplayScope) { await cloud.refreshInvitations() }
            .onChange(of: cloud.session == nil) { _, signedOut in if signedOut { dismiss() } }
            .refreshable { await cloud.refreshInvitations() }
            .confirmationDialog(CloudCopy.text("移除本机日程？"), isPresented: $confirmsRemoval) {
                Button(CloudCopy.text("确认移除"), role: .destructive) {
                    guard let meeting, let account = cloud.currentUserID else { return }
                    Task {
                        do {
                            _ = account
                            try await cloud.removeCalendarProjection(meeting)
                            calendarNotice = CloudCopy.text("已处理此设备中的日程。")
                        } catch { calendarNotice = CloudCopy.error(error) }
                    }
                }.accessibilityIdentifier("cloud.meeting.calendar.remove.confirm")
                Button(CloudCopy.text("取消"), role: .cancel) {}
            }
    }
}

extension CloudShareLink: Identifiable {}
extension CloudFeedLink: Identifiable {}

struct CloudMeetingCalendarView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let meeting: CloudMeeting
    @State private var destinations: [CloudCalendarDestination] = []
    @State private var selected: String?
    @State private var isSaving = false
    @State private var error: String?
    @State private var saved = false
    private let writer = CloudMeetingCalendarWriter()
    var body: some View {
        Form {
            Section {
                Text(meeting.title)
                Text(CloudDatePresentation.dateAndTime(meeting.start, timezone: meeting.timezone))
                Text(CloudCopy.text("保存后遵从所选日历已有的同步及共享规则。之后 App 会核对改期和取消，更新自己创建且未被手动修改的日程。")).font(.footnote).foregroundStyle(.secondary)
            }
            Section(CloudCopy.text("存入自己的日历")) {
                ForEach(destinations) { destination in
                    Button { selected = destination.id; saved = false } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(destination.title).foregroundStyle(.primary); Text(destination.account).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if selected == destination.id { Image(systemName: "checkmark") }
                        }
                    }
                }
                Button(CloudCopy.text("将约定存入系统日历")) {
                    guard let selected, let account = cloud.currentUserID else { return }
                    isSaving = true; error = nil
                    Task {
                        do {
                            _ = account
                            try await cloud.saveCalendar(meeting, calendarID: selected)
                            saved = true
                        }
                        catch { self.error = CloudCopy.error(error) }
                        isSaving = false
                    }
                }.disabled(selected == nil || isSaving || saved)
            }
            if isSaving { ProgressView() }
            if saved {
                Text(CloudCopy.text("已添加到此设备的日历。不会代你发送系统日历邀请。"))
                Button(CloudCopy.text("重试同步保存状态")) {
                    Task {
                        do { try await cloud.acknowledgeCalendarWrite(meeting); error = nil }
                        catch { self.error = CloudCopy.error(error) }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(CloudCopy.text("存入日历"))
            .onChange(of: cloud.session == nil) { _, signedOut in if signedOut { dismiss() } }
            .task {
                do { destinations = try await writer.destinations() }
                catch { self.error = CloudCopy.error(error) }
            }
    }
}

struct CloudSourceAccessView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    let source: CloudSource
    @State private var kind = "grants"
    @State private var records: [CloudAccessRecord] = []
    var body: some View {
        Form {
            Section {
                Picker(CloudCopy.text("类型"), selection: $kind) {
                    Text(CloudCopy.text("已添加的人")).tag("grants")
                    Text(CloudCopy.text("添加链接")).tag("share-links")
                    Text(CloudCopy.text("订阅链接")).tag("feed-links")
                }.accessibilityIdentifier("cloud.access.kind")
                Text(CloudCopy.text("撤销后停止后续访问；已下载的内容不能追回。已经兑换的添加链接需同时撤销对应用户的授权。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if records.isEmpty { Text(CloudCopy.text("暂无记录")).foregroundStyle(.secondary) }
                ForEach(records, id: \.identifier) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        if let userID = record.userId {
                            Text(cloud.displayName(for: userID))
                            Text(userID.uuidString).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        } else { Text(record.id?.uuidString ?? CloudCopy.text("授权")).font(.caption).textSelection(.enabled) }
                        Text(record.privacy.label + " · " + (record.revoked == true ? CloudCopy.text("已撤销") : CloudCopy.text("有效"))).font(.caption)
                        if let expires = record.expiresAt { Text(CloudCopy.format("到期：%@", expires.formatted(date: .abbreviated, time: .shortened))).font(.caption) }
                        if record.revoked != true, let id = record.id ?? record.userId {
                            Button(CloudCopy.text("撤销"), role: .destructive) {
                                Task { await cloud.revokeAccess(source: source, kind: kind, id: id); records = await cloud.accessRecords(source: source, kind: kind) }
                            }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.access.revoke.\(id.uuidString)")
                        }
                    }
                }
            }
            if let error = cloud.errorMessage { Text(error).foregroundStyle(.red) }
        }.navigationTitle(CloudCopy.text("分享授权"))
            .onChange(of: cloud.session == nil) { _, signedOut in if signedOut { dismiss() } }
            .task(id: kind) { records = await cloud.accessRecords(source: source, kind: kind) }
    }
}
