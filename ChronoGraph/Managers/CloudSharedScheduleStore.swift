import Foundation
import Combine
import UIKit

/// Read-only projections of calendars another account has explicitly shared.
/// Events live only in memory and are discarded whenever their authority changes.
@MainActor
final class CloudSharedScheduleStore: ObservableObject {
    struct Issue: Identifiable, Equatable {
        enum Kind: String { case partialCoverage, missingCoverage, stale, unavailable, offline, signInRequired, invalidResponse }
        let sourceID: UUID
        let sourceName: String
        let kind: Kind
        var id: String { sourceID.uuidString + ":" + kind.rawValue }
        var message: String {
            switch kind {
            case .partialCoverage: return "只显示已上传覆盖范围内的日程；范围外的日期未知。"
            case .missingCoverage: return "此日历尚未覆盖当前日期，无法显示日程。"
            case .stale: return "此日历已超过24小时未更新，显示的是最后上传的日程。"
            case .unavailable: return "此日历已无法访问，请刷新分享来源或联系分享者。"
            case .offline: return "暂时无法读取此日历，请检查网络后重试。"
            case .signInRequired: return "登录已失效，请重新登录后读取分享日历。"
            case .invalidResponse: return "此日历返回的数据无法显示，请刷新后重试。"
            }
        }
    }

    typealias Fetch = @MainActor (CloudSharedSource, DateInterval) async throws -> [CloudBusyEvent]
    @Published private(set) var contextScope: String?
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var issues: [Issue] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadedSourceIDs: Set<UUID> = []
    @Published private(set) var loadedInterval: DateInterval?

    private struct SourceAuthority: Equatable {
        let id: UUID
        let ownerID: UUID
        let ownerName: String
        let name: String
        let privacy: String
        let generation: Int
        let start: Date?
        let end: Date?
        let updated: Date?
        init(_ source: CloudSharedSource) {
            id = source.id; ownerID = source.ownerId; ownerName = source.ownerName
            name = source.name; privacy = source.privacy.rawValue; generation = source.generation
            start = source.coverageStart; end = source.coverageEnd; updated = source.lastSyncedAt
        }
    }
    private var authorities: [SourceAuthority] = []
    private var sources: [UUID: CloudSharedSource] = [:]
    private var requestID = UUID()

    func matchesContext(scope: String?, sources: [CloudSharedSource]) -> Bool {
        let scope = scope.flatMap { $0.isEmpty ? nil : $0 }
        let available = scope == nil ? [] : sources
        let next = available.map(SourceAuthority.init).sorted { $0.id.uuidString < $1.id.uuidString }
        return contextScope == scope && authorities == next
    }

    func updateContext(scope: String?, sources: [CloudSharedSource]) {
        let scope = scope.flatMap { $0.isEmpty ? nil : $0 }
        let available = scope == nil ? [] : sources
        let next = available.map(SourceAuthority.init).sorted { $0.id.uuidString < $1.id.uuidString }
        guard contextScope != scope || authorities != next else { return }
        // Invalidate suspended requests before publishing the changed account/permissions.
        requestID = UUID()
        events = []; issues = []; isLoading = false
        loadedSourceIDs = []; loadedInterval = nil
        contextScope = scope
        authorities = next
        self.sources = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    func reset() {
        updateContext(scope: nil, sources: [])
        loadedSourceIDs = []; loadedInterval = nil
    }

    func load(selectedSourceIDs: Set<UUID>, interval: DateInterval, now: Date = Date(), fetch: Fetch) async {
        let request = UUID()
        requestID = request
        events = []; issues = []; isLoading = false
        loadedSourceIDs = []; loadedInterval = nil
        guard let scope = contextScope, interval.start.timeIntervalSince1970.isFinite,
              interval.end.timeIntervalSince1970.isFinite, interval.duration > 0 else { return }
        let selected = selectedSourceIDs.sorted { $0.uuidString < $1.uuidString }.compactMap { sources[$0] }
        guard !selected.isEmpty else { return }
        isLoading = true
        defer { if requestID == request { isLoading = false } }
        var collected: [CalendarEvent] = []
        var problems: [Issue] = []
        func issue(_ source: CloudSharedSource, _ kind: Issue.Kind) -> Issue {
            Issue(sourceID: source.id, sourceName: source.ownerName + " · " + source.name, kind: kind)
        }
        for source in selected {
            guard requestID == request, contextScope == scope, !Task.isCancelled else { return }
            guard let start = source.coverageStart, let end = source.coverageEnd,
                  start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end > start else {
                problems.append(issue(source, .missingCoverage)); continue
            }
            let lower = max(start, interval.start), upper = min(end, interval.end)
            guard upper > lower else { problems.append(issue(source, .missingCoverage)); continue }
            if lower > interval.start || upper < interval.end { problems.append(issue(source, .partialCoverage)) }
            if source.lastSyncedAt.map({ $0 < now.addingTimeInterval(-24 * 60 * 60) }) ?? true {
                problems.append(issue(source, .stale))
            }
            do {
                let requested = DateInterval(start: lower, end: upper)
                let values = try await fetch(source, requested)
                guard requestID == request, contextScope == scope, !Task.isCancelled else { return }
                collected += Self.project(values, source: source, interval: requested)
            } catch {
                guard requestID == request, contextScope == scope, !Task.isCancelled else { return }
                if error is CancellationError { return }
                if case CloudClientError.signIn = error {
                    events = []; issues = [issue(source, .signInRequired)]
                    return
                } else if case CloudClientError.http(let status, _) = error {
                    if status == 401 {
                        events = []; issues = [issue(source, .signInRequired)]
                        return
                    }
                    problems.append(issue(source, status == 403 || status == 404 ? .unavailable : status == 409 ? .missingCoverage : .offline))
                } else if error is DecodingError {
                    problems.append(issue(source, .invalidResponse))
                } else if case CloudClientError.invalidResponse = error {
                    problems.append(issue(source, .invalidResponse))
                } else { problems.append(issue(source, .offline)) }
            }
        }
        guard requestID == request, contextScope == scope, !Task.isCancelled else { return }
        events = collected.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.id < $1.id
        }
        issues = problems
        loadedSourceIDs = Set(selected.map(\.id))
        loadedInterval = interval
    }

    static func project(_ values: [CloudBusyEvent], source: CloudSharedSource, interval: DateInterval) -> [CalendarEvent] {
        let displayName = source.ownerName + " · " + source.name
        var seen = Set<UUID>()
        return values.compactMap { value in
            guard value.start.timeIntervalSince1970.isFinite, value.end.timeIntervalSince1970.isFinite,
                  value.end > value.start, value.start < interval.end, value.end > interval.start,
                  seen.insert(value.id).inserted else { return nil }
            let availability = CalendarEvent.Availability(rawValue: value.availability) ?? .notSupported
            // Apply the grant again locally even if an invalid server response includes forbidden fields.
            let title = source.privacy == .opaque ? availability.localizedName
                : value.title.flatMap { $0.isEmpty ? nil : $0 } ?? NSLocalizedString("event.untitled", comment: "No Title")
            return CalendarEvent(id: "cloud:\(source.id.uuidString):\(value.id.uuidString)", title: title,
                startDate: value.start, endDate: value.end,
                location: source.privacy == .full ? value.location : nil,
                notes: source.privacy == .full ? value.notes : nil,
                calendar: displayName, calendarColor: UIColor.systemIndigo.cgColor,
                isAllDay: value.isAllDay, availability: availability,
                sourceDisplayName: displayName, isReadOnly: true)
        }
    }
}
