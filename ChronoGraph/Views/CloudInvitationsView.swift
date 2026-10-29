import SwiftUI

/// The inbox reads invitations independently of source upload settings.
struct CloudInvitationsView: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List { CloudInvitationSections() }
            .accessibilityIdentifier("cloud.invitations.list")
            .navigationTitle("invitations.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                        .accessibilityIdentifier("cloud.invitations.done")
                }
            }
            .task(id: cloud.homeDisplayScope) { await cloud.refreshInvitations() }
            .refreshable { await cloud.refreshInvitations() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await cloud.refreshInvitations() } }
            }
            .onChange(of: cloud.session == nil) { _, signedOut in
                if signedOut { dismiss() }
            }
    }
}

/// Reused by the inbox and cloud workspace, including identical loading/error states.
struct CloudInvitationSections: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager

    var body: some View {
        if let account = cloud.currentUserID {
            CloudInvitationRefreshStatus()
            let groups = CloudInvitationGroups(meetings: cloud.meetings, userID: account)
            if !groups.pending.isEmpty {
                invitationSection("invitations.section.pending", id: "pending", meetings: groups.pending)
            }
            if !groups.sent.isEmpty {
                invitationSection("invitations.section.sent", id: "sent", meetings: groups.sent)
            }
            if !groups.other.isEmpty {
                invitationSection("invitations.section.other", id: "other", meetings: groups.other)
            }
            if cloud.invitationsHasLoaded && cloud.meetings.isEmpty && cloud.invitationsError == nil && !cloud.invitationsIsLoading {
                Section {
                    Text("invitations.empty").foregroundStyle(.secondary)
                        .accessibilityIdentifier("cloud.invitations.empty")
                }
            } else if !cloud.invitationsHasLoaded && !cloud.invitationsIsLoading && cloud.invitationsError == nil {
                Section { Text("invitations.notLoaded").foregroundStyle(.secondary) }
            }
        } else {
            Section { Text("invitations.signIn").foregroundStyle(.secondary) }
        }
    }

    private func invitationSection(_ title: LocalizedStringKey, id: String, meetings: [CloudMeeting]) -> some View {
        Section {
            ForEach(meetings) { meeting in
                NavigationLink { CloudMeetingDetailView(meetingID: meeting.id) } label: {
                    CloudInvitationRow(meeting: meeting)
                }
                .accessibilityIdentifier("cloud.meeting.open.\(meeting.id.uuidString)")
            }
        } header: {
            Text(title).accessibilityIdentifier("cloud.invitations.\(id)")
        }
    }
}

/// The inbox, workspace, and detail use the same read-only loading and recovery UI.
struct CloudInvitationRefreshStatus: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager

    var body: some View {
        if cloud.invitationsIsLoading {
            Section {
                ProgressView("invitations.loading")
                    .accessibilityIdentifier("cloud.invitations.loading")
            }
        }
        if let error = cloud.invitationsError {
            Section {
                Label("invitations.refreshFailed", systemImage: "exclamationmark.triangle")
                Text(error).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("cloud.invitations.error")
                if cloud.invitationsHasLoaded {
                    Text("invitations.cached").font(.footnote).foregroundStyle(.secondary)
                }
                Button("common.retry") { Task { await cloud.refreshInvitations() } }
                    .accessibilityIdentifier("cloud.invitations.retry")
            }
        }
    }
}

private struct CloudInvitationRow: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    @Environment(\.locale) private var locale
    let meeting: CloudMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
            Text(CloudDatePresentation.dateAndTime(meeting.start, timezone: meeting.timezone, locale: locale) +
                 " · " + CloudDatePresentation.zoneIdentifier(meeting.timezone))
                .font(.caption).foregroundStyle(.secondary)
            Text(LocalizedStringKey(meeting.invitationStatusKey(for: cloud.currentUserID)))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
