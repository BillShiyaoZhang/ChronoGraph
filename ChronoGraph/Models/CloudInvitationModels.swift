import Foundation

extension CloudMeeting {
    /// A response is actionable only before a proposed arrangement starts.
    /// Hosts and guests who already answered do not create a new inbox badge.
    func requiresInvitationResponse(from userID: UUID, at now: Date = Date()) -> Bool {
        status == "proposed" && start > now && hostId != userID &&
            participants.contains { $0.userId == userID && $0.response == "pending" }
    }

    func requiresOrganizerConfirmation(from userID: UUID, at now: Date = Date()) -> Bool {
        status == "proposed" && start > now && hostId == userID && !participants.isEmpty &&
            participants.allSatisfy { $0.response == "accepted" }
    }

    func invitationStatusKey(for userID: UUID?, at now: Date = Date()) -> String {
        switch status {
        case "confirmed": return "invitations.status.confirmed"
        case "cancelled": return "invitations.status.cancelled"
        default:
            if start <= now { return "invitations.status.expired" }
            if status == "proposed", !participants.isEmpty, participants.allSatisfy({ $0.response == "accepted" }) {
                return "invitations.status.ready"
            }
            guard let userID else { return "invitations.status.waiting" }
            if requiresInvitationResponse(from: userID, at: now) { return "invitations.status.pending" }
            switch participants.first(where: { $0.userId == userID })?.response {
            case "accepted" where hostId != userID: return "invitations.status.accepted"
            case "declined": return "invitations.status.declined"
            case "tentative": return "invitations.status.tentative"
            default: return "invitations.status.waiting"
            }
        }
    }
}

struct CloudInvitationGroups {
    let pending: [CloudMeeting]
    let sent: [CloudMeeting]
    let other: [CloudMeeting]

    init(meetings: [CloudMeeting], userID: UUID, now: Date = Date()) {
        pending = meetings.filter { $0.requiresInvitationResponse(from: userID, at: now) }
            .sorted { $0.start < $1.start }
        sent = meetings.filter { $0.hostId == userID }.sorted { $0.start > $1.start }
        other = meetings.filter { $0.hostId != userID && !$0.requiresInvitationResponse(from: userID, at: now) }
            .sorted { $0.start > $1.start }
    }
}
