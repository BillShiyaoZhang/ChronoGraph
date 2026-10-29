import SwiftUI

enum CalendarSharingChannel {
    case calendarAccount, cloud

    var title: LocalizedStringKey {
        switch self {
        case .calendarAccount: return "sharing.channel.account"
        case .cloud: return "sharing.channel.cloud"
        }
    }

    var systemImage: String {
        switch self {
        case .calendarAccount: return "calendar.badge.person.crop"
        case .cloud: return "icloud"
        }
    }
}

struct SharingChannelLabel: View {
    let channel: CalendarSharingChannel
    var body: some View { Label(channel.title, systemImage: channel.systemImage) }
}

/// Common source presentation; each service keeps its own eligibility and selection policy.
struct SharingSourceRow: View {
    let title: String
    let account: String
    let isSelected: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                Text(account).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected { Image(systemName: "checkmark") }
        }
        .contentShape(Rectangle())
    }
}

/// Identical date controls for viewing and outgoing services. Applying only edits the supplied draft.
struct SharingRangeFields: View {
    @Binding var range: SharedCalendarRange
    let identifierPrefix: String
    let onCustom: () -> Void

    var body: some View {
        SharedRangeSummary(range: range)
        DateRangeMenu(selection: range, onSelect: { range = $0 }, onCustom: onCustom,
                      identifierPrefix: identifierPrefix, showsTitle: true, includesCustomRange: false)
        Button("dateRange.custom", action: onCustom)
            .accessibilityIdentifier(identifierPrefix + ".customize")
        LabeledContent("sharing.range.timeZone", value: range.timeZoneIdentifier)
    }
}

struct SharingContentPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: PrivacyMode
    let identifierPrefix: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(PrivacyMode.allCases, id: \.rawValue) { mode in
                Text(mode.localizedKey).tag(mode).accessibilityIdentifier(identifierPrefix + "." + mode.rawValue)
            }
        }
        .accessibilityIdentifier(identifierPrefix)
    }
}

struct SharingScopeSummary: View {
    let channel: CalendarSharingChannel
    let range: SharedCalendarRange
    let sourceCount: Int
    let content: PrivacyMode
    var destination: String? = nil
    var contentTitle: LocalizedStringKey = "sharing.scope.content"

    var body: some View {
        LabeledContent("sharing.scope.channel") { SharingChannelLabel(channel: channel) }
        if let destination { LabeledContent("sharing.scope.destination", value: destination) }
        LabeledContent("settings.calendars", value: sourceCount.formatted())
        SharedRangeSummary(range: range)
        LabeledContent(contentTitle) { Text(content.localizedKey) }
    }
}

/// List subtitles distinguish a configuration default from the server's field ceiling.
struct CloudSharingSourceSubtitle: View {
    @EnvironmentObject private var cloud: CloudWorkspaceManager
    let source: CloudSource
    private var binding: CloudLocalBinding? { cloud.bindings.first { $0.sourceId == source.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let draft = binding?.sharing {
                Text("cloud.sharing.defaultVisibility") + Text(" · ") + Text(draft.defaultVisibility.localizedKey)
            }
            Text("cloud.sharing.review.maximumDetails") + Text(" · ") + Text(source.uploadLevel.label)
            if binding?.hasPendingScope == true { Text("cloud.sharing.pending.status") }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
