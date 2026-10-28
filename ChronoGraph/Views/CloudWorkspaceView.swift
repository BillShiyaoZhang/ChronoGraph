import SwiftUI
import AuthenticationServices

struct CloudWorkspaceView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var server = ""
    @State private var nickname = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var inviteCode = ""
    @State private var registrationName = ""
    @State private var registering = false
    @State private var showingPasswordChange = false
    @FocusState private var authFocus: AuthField?
    private enum AuthField: Hashable { case username, password, confirmation, invite, name, server, nickname, incoming }
    @State private var confirmsAccountDeletion = false
    @State private var showingAccessibleDeletionReview = false
    @State private var showingSources = false
    @State private var showingFind = false
    @State private var incomingToken = ""
    @State private var sharing: CloudShareLink?
    @State private var publicFeed: CloudFeedLink?
    @State private var removal: CloudSource?

    var body: some View {
        Form {
            Section {
                Text("云端协作 · 测试版").font(.headline)
                Text("在所选服务器保存你明确启用的忙闲数据、分享权限和邀约。原有本机查看、图片导出和 iCloud 共享继续独立使用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if cloud.session == nil { connectionSection; passwordSection }
            else { accountSections }
            if cloud.isBusy { Section { ProgressView("正在处理…") } }
            if let error = cloud.errorMessage { Section { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("cloud.error") } }
            if let notice = cloud.notice { Section { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("cloud.notice") } }
            if let status = cloud.calendarSyncStatus { Section { Text(status).font(.footnote).foregroundStyle(.secondary) } }
        }
        .id(cloud.session?.user.id)
        .navigationTitle("云端协作")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { authFocus = nil }.accessibilityIdentifier("cloud.auth.keyboard.done")
            }
        }
        .task {
            server = cloud.endpoint
            nickname = cloud.session?.user.displayName ?? ""
            if cloud.session != nil { await cloud.refresh() }
            else if cloud.appleSignInAvailable && !server.isEmpty { await cloud.prepareSignIn() }
        }
        .refreshable { if cloud.session != nil { await cloud.refresh() } }
        .onChange(of: cloud.session?.user.displayName) { _, value in nickname = value ?? "" }
        .onChange(of: cloud.session?.user.id) { _, value in if value != nil { clearSecrets(); registering = false } }
        .onDisappear { clearSecrets() }
        .sheet(isPresented: $showingPasswordChange) { NavigationStack { CloudPasswordChangeView() } }
        .confirmationDialog("删除云端账号？", isPresented: $confirmsAccountDeletion, titleVisibility: .visible) {
            Button("删除账号及云端数据", role: .destructive) { Task { await cloud.deleteAccount() } }.accessibilityIdentifier("cloud.account.delete.confirm")
            Button("取消", role: .cancel) {}.accessibilityIdentifier("cloud.account.delete.cancel")
        } message: {
            Text(CloudAccountDeletionPresentation.disclosure)
        }
        .sheet(isPresented: $showingAccessibleDeletionReview) { CloudAccessibleAccountDeletionReview() }
        .sheet(isPresented: $showingSources) { NavigationStack { CloudSourcePickerView() } }
        .sheet(isPresented: $showingFind) { NavigationStack { CloudFindTimeView() } }
        .sheet(item: $sharing) { link in
            NavigationStack {
                Form {
                    Section("添加此日历") {
                        Text("收到链接的人可以登录同一服务器并添加你允许分享的日历。请只发送给愿意授权的人。")
                        ShareLink(item: link.joinUrl) { Label("分享添加链接", systemImage: "square.and.arrow.up") }
                        Text(link.joinUrl.absoluteString).font(.footnote).textSelection(.enabled)
                        Text("到期：\(link.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                }.navigationTitle("分享日历")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sharing = nil } } }
            }
        }
        .sheet(item: $publicFeed) { link in
            NavigationStack {
                Form {
                    Section("公开订阅链接") {
                        Text("任何持有此链接的人都可读取允许分享的内容，并可转发链接。已下载的副本不能追回。")
                        ShareLink(item: link.url) { Label("发送订阅链接", systemImage: "link") }
                        Text(link.url.absoluteString).font(.footnote).textSelection(.enabled)
                    }
                    Section {
                        Button("撤销此订阅链接", role: .destructive) {
                            Task { await cloud.revokeFeed(link); if cloud.errorMessage == nil { publicFeed = nil } }
                        }.accessibilityIdentifier("cloud.feed.revoke")
                    }
                }.navigationTitle("订阅日历")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { publicFeed = nil } } }
            }
        }
        .confirmationDialog("删除云端来源？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            if let removal {
                Button("删除云端来源", role: .destructive) { Task { await cloud.removeSource(removal); self.removal = nil } }.accessibilityIdentifier("cloud.source.delete.confirm")
            }
            Button("取消", role: .cancel) { removal = nil }.accessibilityIdentifier("cloud.source.delete.cancel")
        } message: { Text("停止上传并删除此来源的云端数据和分享。不会删除系统日历中的原始日程，已下载的内容不能追回。") }
    }

    private var connectionSection: some View {
        Section {
            TextField("HTTPS 服务器地址", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .focused($authFocus, equals: .server).submitLabel(.done).onSubmit { authFocus = nil }.accessibilityIdentifier("cloud.server")
            Button("保存服务器") { Task { await cloud.configure(server) } }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.configure")
            if cloud.appleSignInAvailable && cloud.challenge != nil {
                SignInWithAppleButton(.signIn, onRequest: cloud.configureAppleRequest) { result in
                    Task { await cloud.completeAppleSignIn(result) }
                }.frame(height: 48).disabled(cloud.isBusy)
            }
        } header: { Text("连接你的服务器") }
        footer: { Text("登录不等于上传授权。添加日历时会再次展示上传范围。") }
    }
    private var passwordSection: some View {
        Section {
            TextField("用户名", text: $username)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.asciiCapable).submitLabel(.next).focused($authFocus, equals: .username)
                .onSubmit { authFocus = .password }.accessibilityIdentifier("cloud.auth.username")
            SecureField(registering ? "设置密码（至少12个字符）" : "密码", text: $password)
                .textContentType(registering ? .newPassword : .password)
                .submitLabel(registering ? .next : .go).focused($authFocus, equals: .password)
                .onSubmit { if registering { authFocus = .confirmation } else { submitPassword() } }
                .accessibilityIdentifier("cloud.auth.password")
                .id(registering ? "registration-password" : "login-password")
            if registering {
                SecureField("再次输入密码", text: $confirmation).textContentType(.newPassword)
                    .submitLabel(.next).focused($authFocus, equals: .confirmation)
                    .onSubmit { authFocus = .invite }.accessibilityIdentifier("cloud.auth.confirmation")
                TextField("邀请码", text: $inviteCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.next).focused($authFocus, equals: .invite)
                    .onSubmit { authFocus = .name }.accessibilityIdentifier("cloud.auth.invite")
                TextField("昵称（可选）", text: $registrationName).textContentType(.nickname)
                    .submitLabel(.go).focused($authFocus, equals: .name)
                    .onSubmit { submitPassword() }.accessibilityIdentifier("cloud.auth.displayName")
                Text("用户名为3至32位英文字母、数字、点、下划线或短横线。密码为12至128个字符，区分大小写并保留空格。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button(registering ? "注册并登录" : "登录") { submitPassword() }
                .disabled(cloud.isBusy || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || username.isEmpty || password.isEmpty)
                .accessibilityIdentifier(registering ? "cloud.password.register" : "cloud.password.login")
            Button(registering ? "已有账号？登录" : "有邀请码？创建账号") {
                clearSecrets(); registering.toggle(); cloud.errorMessage = nil; cloud.notice = nil; authFocus = .username
            }.disabled(cloud.isBusy).accessibilityIdentifier(registering ? "cloud.auth.showLogin" : "cloud.auth.showRegister")
        } header: { Text(registering ? "邀请码注册" : "账号密码登录") }
        footer: { Text("账号仅用于当前服务器。忘记密码请联系管理员重置。登录后仍需单独选择允许上传的日历。") }
    }
    private func clearSecrets() { password = ""; confirmation = ""; inviteCode = "" }
    private func submitPassword() {
        guard !cloud.isBusy else { return }
        guard !registering || CloudPasswordPolicy.matches(password, confirmation) else {
            cloud.errorMessage = CloudClientError.passwordMismatch.localizedDescription; return
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
    @ViewBuilder private var accountSections: some View {
        Section("账号") {
            TextField("对外显示昵称", text: $nickname)
                .focused($authFocus, equals: .nickname).submitLabel(.done).onSubmit { authFocus = nil }
                .accessibilityIdentifier("cloud.nickname")
            Button("保存昵称") { Task { await cloud.updateDisplayName(nickname) } }
                .disabled(cloud.isBusy || nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nickname.unicodeScalars.count > 100)
                .accessibilityIdentifier("cloud.nickname.save")
            if let id = cloud.currentUserID { LabeledContent("我的账号编号") { Text(id.uuidString).font(.caption).textSelection(.enabled) } }
            if cloud.session?.usesPassword == true {
                LabeledContent("登录方式", value: "账号密码")
                Button("修改密码") { cloud.errorMessage = nil; showingPasswordChange = true }
                    .disabled(cloud.isBusy).accessibilityIdentifier("cloud.password.change.open")
            }
            Text(cloud.endpoint).font(.caption).foregroundStyle(.secondary)
            Button("刷新云端状态") { Task { await cloud.refresh() } }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.refresh")
        }
        Section {
            ForEach(cloud.sources) { source in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(source.name).accessibilityIdentifier("cloud.source.name.\(source.id.uuidString)"); Spacer(); Text(source.uploadLevel.label).font(.caption).foregroundStyle(.secondary) }
                    Text(source.lastSyncedAt.map { "最后上传：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未上传日程")
                        .font(.caption).foregroundStyle(.secondary)
                    if let start = source.coverageStart, let end = source.coverageEnd {
                        Text("覆盖：\(start.formatted(date: .abbreviated, time: .omitted))—\(end.formatted(date: .abbreviated, time: .omitted))（结束边界不含）")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink("管理已发出的授权") { CloudSourceAccessView(source: source) }.accessibilityIdentifier("cloud.source.access.\(source.id.uuidString)")
                    Menu("分享与管理") {
                        Button("创建站内添加链接") { Task { sharing = await cloud.createShareLink(source) } }.accessibilityIdentifier("cloud.source.share")
                        Button("创建公开 ICS 订阅") { Task { publicFeed = await cloud.createFeedLink(source) } }.accessibilityIdentifier("cloud.source.feed")
                        Button("删除云端来源", role: .destructive) { removal = source }.accessibilityIdentifier("cloud.source.delete")
                    }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.source.menu.\(source.id.uuidString)")
                }.padding(.vertical, 4)
            }
            Button("添加我的日历") { showingSources = true }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.source.add")
            if !cloud.bindings.isEmpty { Button("同步所选日历") { Task { await cloud.sync() } }.disabled(cloud.isBusy) }
        } header: { Text("我的云端来源") }
        footer: { Text("只自动上传已经明确启用的来源。覆盖范围以设备成功上传为准；手机离线时云端数据可能过旧。") }
        Section("别人分享的") {
            ForEach(cloud.sharedSources) { source in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(source.ownerName) · \(source.name)")
                    Text(source.lastSyncedAt.map { "来源更新时间：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "来源尚未同步")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("粘贴添加链接或令牌", text: $incomingToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($authFocus, equals: .incoming).submitLabel(.done).onSubmit { authFocus = nil }.accessibilityIdentifier("cloud.incoming.token")
            Button("添加日历") { Task { await cloud.redeem(incomingToken); if cloud.errorMessage == nil { incomingToken = "" } } }
                .disabled(cloud.isBusy || incomingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("cloud.incoming.add")
        }
        Section("约时间") {
            Button("寻找共同候选") { showingFind = true }.disabled(cloud.isBusy || cloud.sources.isEmpty || cloud.sharedSources.isEmpty).accessibilityIdentifier("cloud.find.open")
            if cloud.meetings.isEmpty { Text("尚无邀约").foregroundStyle(.secondary) }
            ForEach(cloud.meetings) { meeting in
                NavigationLink { CloudMeetingDetailView(meetingID: meeting.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title)
                        Text("\(CloudDatePresentation.dateAndTime(meeting.start, timezone: meeting.timezone)) · \(CloudDatePresentation.zoneIdentifier(meeting.timezone)) · \(meetingStatus(meeting.status))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("cloud.meeting.open.\(meeting.id.uuidString)")
            }
        }
        Section {
            Button("退出此设备", role: .destructive) { Task { await cloud.signOut() } }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.logout")
            Button("删除云端账号", role: .destructive) {
                if dynamicTypeSize.isAccessibilitySize { showingAccessibleDeletionReview = true }
                else { confirmsAccountDeletion = true }
            }
                .disabled(cloud.isBusy).accessibilityIdentifier("cloud.account.delete")
        }
    }
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
                SecureField("当前密码", text: $current).textContentType(.password)
                    .focused($focused, equals: .current).submitLabel(.next)
                    .onSubmit { focused = .new }.accessibilityIdentifier("cloud.password.current")
                SecureField("新密码（至少12个字符）", text: $new).textContentType(.newPassword)
                    .focused($focused, equals: .new).submitLabel(.next)
                    .onSubmit { focused = .confirmation }.accessibilityIdentifier("cloud.password.new")
                SecureField("再次输入新密码", text: $confirmation).textContentType(.newPassword)
                    .focused($focused, equals: .confirmation).submitLabel(.go)
                    .onSubmit { submit() }.accessibilityIdentifier("cloud.password.newConfirmation")
            } footer: { Text("密码为12至128个字符。修改后其他设备需要重新登录，本机继续保持登录。") }
            Section {
                Button("保存新密码") { submit() }.disabled(cloud.isBusy || current.isEmpty || new.isEmpty || confirmation.isEmpty)
                    .accessibilityIdentifier("cloud.password.change.save")
                if cloud.isBusy { ProgressView("正在处理…") }
            }
            if let error = cloud.errorMessage { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("cloud.password.change.error") } }
        }.navigationTitle("修改密码").navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.password.change.cancel") }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focused = nil }.accessibilityIdentifier("cloud.auth.keyboard.done")
                }
            }
            .interactiveDismissDisabled(cloud.isBusy)
            .onDisappear { current = ""; new = ""; confirmation = "" }
            .onChange(of: cloud.session?.user.id) { _, value in if value == nil { dismiss() } }
    }
    private func submit() {
        guard !cloud.isBusy else { return }
        guard CloudPasswordPolicy.matches(new, confirmation) else { cloud.errorMessage = CloudClientError.passwordMismatch.localizedDescription; return }
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
    static let disclosure = "将删除此账号的云端来源、分享和登录会话，并取消关联的活跃约定。他人的协调历史中会保留匿名记录。本机和 iCloud 中的原始日历、已保存日程均保留，需在系统日历中自行处理。Apple 登录授权请单独管理。"
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
                    Button("删除账号及云端数据", role: .destructive) {
                        Task {
                            await cloud.deleteAccount()
                            if cloud.session == nil { dismiss() }
                        }
                    }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.account.delete.confirm")
                    if cloud.isBusy { ProgressView("正在处理…") }
                }
                if let error = cloud.errorMessage {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("cloud.account.delete.error") }
                }
            }
            .navigationTitle("删除云端账号？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(cloud.isBusy).accessibilityIdentifier("cloud.account.delete.cancel")
                }
            }
        }.interactiveDismissDisabled(cloud.isBusy)
    }
}

private func meetingStatus(_ status: String) -> String {
    switch status { case "confirmed": return "已定档"; case "cancelled": return "已取消"; default: return "等待回应" }
}
private func responseLabel(_ response: String) -> String {
    switch response { case "accepted": return "已同意"; case "declined": return "不方便"; case "tentative": return "待定"; default: return "待回应" }
}

struct CloudSourcePickerView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var level: CloudUploadLevel = .opaque
    @State private var consent = false
    var body: some View {
        Form {
            Section("选择你自己的日历") {
                ForEach(cloud.calendars) { calendar in
                    Button { selected = calendar.id; consent = false } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(calendar.title).foregroundStyle(.primary); Text(calendar.account).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if selected == calendar.id { Image(systemName: "checkmark") }
                        }
                    }.disabled(cloud.bindings.contains { $0.calendarId == calendar.id }).accessibilityIdentifier("cloud.upload.calendar.\(calendar.id)")
                }
            }
            Section {
                Text("请选择属于你的日历；公共订阅和应用维护的副本已自动排除。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("允许上传的内容") { Picker("字段", selection: $level) { ForEach(CloudUploadLevel.allCases) { Text($0.label).tag($0) } }.accessibilityIdentifier("cloud.upload.level") }
                .onChange(of: level) { _, _ in consent = false }
            Section {
                Text("目标服务器：\(cloud.endpoint)").font(.footnote)
                Text("将过去7天至未来90天的所选字段上传并持续更新。完整模式包含原始备注；仅忙闲也会暴露时间规律。尚未分享给任何其他账号。")
                    .font(.footnote)
                Text("云端上传不沿用既有 iCloud 共享中的逐条‘不分享’规则；所选日历在上述日期内的事件都会按所选级别上传。")
                    .font(.footnote).accessibilityIdentifier("cloud.upload.independentRules")
                Toggle("我同意向此服务器上传以上日历数据", isOn: $consent).accessibilityIdentifier("cloud.upload.consent")
                Button("确认启用并上传") {
                    guard let calendar = cloud.calendars.first(where: { $0.id == selected }) else { return }
                    Task { await cloud.enableCalendar(calendar, level: level); if cloud.errorMessage == nil { dismiss() } }
                }.disabled(!consent || selected == nil || cloud.isBusy).accessibilityIdentifier("cloud.upload.confirm")
            }
            if cloud.isBusy { ProgressView() }
            if let error = cloud.errorMessage { Text(error).foregroundStyle(.red) }
        }.navigationTitle("启用云同步")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .task { await cloud.loadCalendars() }
    }
}

struct CloudFindTimeView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPeople: Set<UUID> = []
    @State private var days = 7
    @State private var duration = 60
    @State private var dailyStart = "09:00"
    @State private var dailyEnd = "21:00"
    @State private var title = "约时间"
    @State private var selectedCandidate: CloudCandidate?
    private var people: [(id: UUID, name: String)] {
        Dictionary(grouping: cloud.sharedSources, by: \.ownerId).map { (id: $0.key, name: $0.value.first?.ownerName ?? "参与者") }.sorted { $0.name < $1.name }
    }
    var body: some View {
        Form {
            Section("参与者（我默认参加）") {
                ForEach(people, id: \.id) { person in
                    Toggle(person.name, isOn: Binding(get: { selectedPeople.contains(person.id) }, set: { if $0 { selectedPeople.insert(person.id) } else { selectedPeople.remove(person.id) } })).accessibilityIdentifier("cloud.find.person.\(person.id.uuidString)")
                }
            }
            Section("查找条件") {
                Picker("日期", selection: $days) { Text("未来3天").tag(3); Text("未来7天").tag(7); Text("未来14天").tag(14) }.accessibilityIdentifier("cloud.find.days")
                Picker("时长", selection: $duration) { Text("30分钟").tag(30); Text("60分钟").tag(60); Text("90分钟").tag(90) }.accessibilityIdentifier("cloud.find.duration")
                TextField("每日开始 HH:mm", text: $dailyStart).keyboardType(.numbersAndPunctuation)
                TextField("每日结束 HH:mm", text: $dailyEnd).keyboardType(.numbersAndPunctuation)
                Text("时区：\(TimeZone.current.identifier)").font(.caption).foregroundStyle(.secondary)
                Button("查找共同候选") { Task { await cloud.search(selectedPeople: selectedPeople, days: days, duration: duration, dailyStart: dailyStart, dailyEnd: dailyEnd) } }
                    .disabled(selectedPeople.isEmpty || cloud.isBusy).accessibilityIdentifier("cloud.find.search")
            }
            if let availability = cloud.availability {
                Section("共同候选 · 待确认") {
                    Text("候选时区：\(CloudDatePresentation.zoneIdentifier(availability.timezone))")
                    TextField("邀约标题", text: $title).accessibilityIdentifier("cloud.find.title")
                    if availability.windows.isEmpty { Text("没有符合条件的时间。请缩短时长或调整日期、时段。") }
                    ForEach(availability.windows) { candidate in
                        Button { selectedCandidate = candidate } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(CloudDatePresentation.dateAndTime(candidate.suggestedStart, timezone: availability.timezone))
                                Text("至 \(CloudDatePresentation.time(candidate.suggestedEnd, timezone: availability.timezone))").font(.caption)
                            }
                        }.accessibilityIdentifier("cloud.find.candidate")
                    }
                    Text("基于最后上传的日程；未分享事项可能仍有冲突。创建邀约不会自动占用他人的系统日历。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if cloud.isBusy { ProgressView() }
            if let error = cloud.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("cloud.error") }
        }.navigationTitle("找时间")
            .onChange(of: selectedPeople) { _, _ in cloud.invalidateCandidates() }
            .onChange(of: days) { _, _ in cloud.invalidateCandidates() }
            .onChange(of: duration) { _, _ in cloud.invalidateCandidates() }
            .onChange(of: dailyStart) { _, _ in cloud.invalidateCandidates() }
            .onChange(of: dailyEnd) { _, _ in cloud.invalidateCandidates() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("发起这个时间的邀约？", isPresented: Binding(get: { selectedCandidate != nil }, set: { if !$0 { selectedCandidate = nil } })) {
                if let candidate = selectedCandidate {
                    Button("发起邀约") { Task { await cloud.propose(candidate, title: title); if cloud.errorMessage == nil { dismiss() }; selectedCandidate = nil } }.accessibilityIdentifier("cloud.find.propose")
                    ShareLink(item: CloudDatePresentation.share(start: candidate.suggestedStart, end: candidate.suggestedEnd, timezone: cloud.availability?.timezone ?? TimeZone.current.identifier)) { Text("分享候选时间") }
                }
                Button("取消", role: .cancel) { selectedCandidate = nil }.accessibilityIdentifier("cloud.find.propose.cancel")
            }
    }
}

struct CloudMeetingDetailView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    let meetingID: UUID
    @State private var calendarNotice: String?
    @State private var confirmsRemoval = false
    private let writer = CloudMeetingCalendarWriter()
    private var meeting: CloudMeeting? { cloud.meetings.first { $0.id == meetingID } }
    var body: some View {
        Form {
            if let meeting {
                Section {
                    Text(meeting.title).font(.headline)
                    Text(CloudDatePresentation.dateAndTime(meeting.start, timezone: meeting.timezone)).accessibilityIdentifier("cloud.meeting.start")
                    Text("至 \(CloudDatePresentation.time(meeting.end, timezone: meeting.timezone)) · \(CloudDatePresentation.zoneIdentifier(meeting.timezone))")
                    Text("\(meetingStatus(meeting.status)) · 第\(meeting.revision)版").foregroundStyle(.secondary)
                }
                Section("参与者") {
                    ForEach(meeting.participants) { person in
                        LabeledContent(person.userId == cloud.currentUserID ? "我" : person.userId.uuidString) {
                            Text(responseLabel(person.response)).accessibilityIdentifier("cloud.meeting.response.\(person.userId.uuidString)")
                        }.font(.subheadline)
                    }
                }
                if meeting.status == "proposed" {
                    Section {
                        Button("同意这个版本") { Task { await cloud.meetingAction(meeting, action: "response", response: "accepted") } }.accessibilityIdentifier("cloud.meeting.accept")
                        Button("待定") { Task { await cloud.meetingAction(meeting, action: "response", response: "tentative") } }.accessibilityIdentifier("cloud.meeting.tentative")
                        Button("不方便") { Task { await cloud.meetingAction(meeting, action: "response", response: "declined") } }.accessibilityIdentifier("cloud.meeting.decline")
                        if meeting.hostId == cloud.currentUserID {
                            Button("全员同意后定档") { Task { await cloud.meetingAction(meeting, action: "confirm") } }
                                .disabled(!meeting.participants.allSatisfy { $0.response == "accepted" }).accessibilityIdentifier("cloud.meeting.confirm")
                            Button("取消邀约", role: .destructive) { Task { await cloud.meetingAction(meeting, action: "cancel") } }.accessibilityIdentifier("cloud.meeting.cancel")
                        }
                    }.disabled(cloud.isBusy)
                }
                if meeting.status == "confirmed" {
                    Section {
                        if meeting.hostId == cloud.currentUserID {
                            Button("取消已定档约定", role: .destructive) { Task { await cloud.meetingAction(meeting, action: "cancel") } }
                                .disabled(cloud.isBusy).accessibilityIdentifier("cloud.meeting.cancelConfirmed")
                        }
                        NavigationLink("添加到我的日历") { CloudMeetingCalendarView(meeting: meeting) }.accessibilityIdentifier("cloud.meeting.calendar")
                        Text("App 内定档与写入系统日历是两种状态。请明确选择自己的可写日历。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
                if let meeting, meeting.status == "cancelled" {
                    Section {
                        Button("移除此设备中由 App 创建的日程", role: .destructive) { confirmsRemoval = true }
                        Text("仅核对并移除 ChronoGraph 为此约定创建的日程；手动修改的日程需在系统日历处理。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            if let calendarNotice { Text(calendarNotice).foregroundStyle(.secondary) }
            if cloud.isBusy { ProgressView() }
            if let error = cloud.errorMessage { Text(error).foregroundStyle(.red).accessibilityIdentifier("cloud.error") }
        }.navigationTitle("邀约详情").task { await cloud.refresh() }
            .refreshable { await cloud.refresh() }
            .confirmationDialog("移除本机日程？", isPresented: $confirmsRemoval) {
                Button("确认移除", role: .destructive) {
                    guard let meeting, let account = cloud.currentUserID else { return }
                    Task {
                        do {
                            _ = account
                            try await cloud.removeCalendarProjection(meeting)
                            calendarNotice = "已处理此设备中的日程。"
                        } catch { calendarNotice = error.localizedDescription }
                    }
                }.accessibilityIdentifier("cloud.meeting.calendar.remove.confirm")
                Button("取消", role: .cancel) {}
            }
    }
}

extension CloudShareLink: Identifiable {}
extension CloudFeedLink: Identifiable {}

struct CloudMeetingCalendarView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
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
                Text("保存后遵从所选日历已有的同步及共享规则。之后 App 会核对改期和取消，更新自己创建且未被手动修改的日程。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("存入自己的日历") {
                ForEach(destinations) { destination in
                    Button { selected = destination.id; saved = false } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(destination.title).foregroundStyle(.primary); Text(destination.account).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if selected == destination.id { Image(systemName: "checkmark") }
                        }
                    }
                }
                Button("添加到我的日历") {
                    guard let selected, let account = cloud.currentUserID else { return }
                    isSaving = true; error = nil
                    Task {
                        do {
                            _ = account
                            try await cloud.saveCalendar(meeting, calendarID: selected)
                            saved = true
                        }
                        catch { self.error = error.localizedDescription }
                        isSaving = false
                    }
                }.disabled(selected == nil || isSaving || saved)
            }
            if isSaving { ProgressView() }
            if saved {
                Text("已添加到此设备的日历。不会代你发送系统日历邀请。")
                Button("更新服务器写回状态") {
                    Task {
                        do { try await cloud.acknowledgeCalendarWrite(meeting); error = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("存入日历")
            .task {
                do { destinations = try await writer.destinations() }
                catch { self.error = error.localizedDescription }
            }
    }
}

struct CloudSourceAccessView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    let source: CloudSource
    @State private var kind = "grants"
    @State private var records: [CloudAccessRecord] = []
    var body: some View {
        Form {
            Section {
                Picker("类型", selection: $kind) {
                    Text("已添加的人").tag("grants")
                    Text("添加链接").tag("share-links")
                    Text("订阅链接").tag("feed-links")
                }.accessibilityIdentifier("cloud.access.kind")
                Text("撤销后停止后续访问；已下载的内容不能追回。已经兑换的添加链接需同时撤销对应用户的授权。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if records.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
                ForEach(records, id: \.identifier) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Text((record.userId ?? record.id)?.uuidString ?? "授权").font(.caption).textSelection(.enabled)
                        Text("\(record.privacy.label) · \(record.revoked == true ? "已撤销" : "有效")").font(.caption)
                        if let expires = record.expiresAt { Text("到期：\(expires.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                        if record.revoked != true, let id = record.id ?? record.userId {
                            Button("撤销", role: .destructive) {
                                Task { await cloud.revokeAccess(source: source, kind: kind, id: id); records = await cloud.accessRecords(source: source, kind: kind) }
                            }.disabled(cloud.isBusy).accessibilityIdentifier("cloud.access.revoke.\(id.uuidString)")
                        }
                    }
                }
            }
            if let error = cloud.errorMessage { Text(error).foregroundStyle(.red) }
        }.navigationTitle("分享授权")
            .task(id: kind) { records = await cloud.accessRecords(source: source, kind: kind) }
    }
}
