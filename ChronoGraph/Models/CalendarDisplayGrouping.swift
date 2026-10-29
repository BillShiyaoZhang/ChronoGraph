import Foundation

/// Account identity comes from EventKit's source ID; a matching title is only a label.
enum CalendarDisplayGrouping {
    struct Item: Equatable, Sendable {
        let id: String
        let title: String
        let sourceID: String
        let sourceTitle: String
    }
    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let calendarIDs: [String]
        let duplicateTitleIndex: Int?
    }
    enum CalendarKind: Equatable, Sendable {
        case ordinary, managedCopy, subscription, readOnly
        var labelKey: String? {
            switch self {
            case .ordinary: return nil
            case .managedCopy: return "calendars.sharedCopy"
            case .subscription: return "calendars.subscription"
            case .readOnly: return "calendars.readOnly"
            }
        }
    }

    static func kind(isManaged: Bool, isSubscribed: Bool, allowsContentModifications: Bool) -> CalendarKind {
        if isManaged { return .managedCopy }
        if isSubscribed { return .subscription }
        return allowsContentModifications ? .ordinary : .readOnly
    }

    static func groups(_ items: [Item]) -> [Group] {
        let priority = ["iCloud": 0, "Exchange": 1, "Gmail": 2, "Yahoo": 3]
        let accounts = Dictionary(grouping: items, by: \.sourceID).map { id, values in
            (id: id, title: values.first?.sourceTitle ?? "", calendars: values.sorted {
                let order = $0.title.localizedCaseInsensitiveCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            })
        }.sorted {
            let firstPriority = priority[$0.title] ?? 99
            let secondPriority = priority[$1.title] ?? 99
            if firstPriority != secondPriority { return firstPriority < secondPriority }
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        let titleCounts = Dictionary(grouping: accounts, by: { $0.title.lowercased() }).mapValues(\.count)
        var seenTitles: [String: Int] = [:]
        return accounts.map { account in
            let titleKey = account.title.lowercased()
            seenTitles[titleKey, default: 0] += 1
            return Group(id: account.id, title: account.title, calendarIDs: account.calendars.map(\.id),
                         duplicateTitleIndex: titleCounts[titleKey, default: 0] > 1 ? seenTitles[titleKey] : nil)
        }
    }
}

struct CloudReceivedCalendarGroup: Identifiable {
    let id: UUID
    let ownerName: String
    let sources: [CloudSharedSource]

    static func groups(_ sources: [CloudSharedSource]) -> [Self] {
        Dictionary(grouping: sources, by: \.ownerId).map { id, values in
            Self(id: id, ownerName: values.first?.ownerName ?? "", sources: values.sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            })
        }.sorted {
            let order = $0.ownerName.localizedCaseInsensitiveCompare($1.ownerName)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
}

/// Every entry is exactly one list row, including owner headings.
enum CloudReceivedCalendarRow: Identifiable {
    case owner(id: UUID, name: String)
    case calendar(CloudSharedSource)

    enum ID: Hashable {
        case owner(UUID)
        case calendar(UUID)
    }

    var id: ID {
        switch self {
        case .owner(let id, _): return .owner(id)
        case .calendar(let source): return .calendar(source.id)
        }
    }

    static func rows(_ sources: [CloudSharedSource]) -> [Self] {
        CloudReceivedCalendarGroup.groups(sources).flatMap { group -> [Self] in
            [.owner(id: group.id, name: group.ownerName)] + group.sources.map { .calendar($0) }
        }
    }
}
