import Foundation

/// Times are formatted in the zone printed next to them, not silently in the viewer's zone.
enum CloudDatePresentation {
    static func zoneIdentifier(_ identifier: String) -> String { TimeZone(identifier: identifier)?.identifier ?? "GMT" }
    static func dateAndTime(_ date: Date, timezone: String, locale: Locale = .current) -> String {
        string(date, timezone: timezone, locale: locale, dateStyle: .medium)
    }
    static func time(_ date: Date, timezone: String, locale: Locale = .current) -> String {
        string(date, timezone: timezone, locale: locale, dateStyle: .none)
    }
    static func share(start: Date, end: Date, timezone: String, locale: Locale = .current) -> String {
        "\(dateAndTime(start, timezone: timezone, locale: locale))—\(time(end, timezone: timezone, locale: locale))（\(zoneIdentifier(timezone))），方便吗？"
    }
    private static func string(_ date: Date, timezone: String, locale: Locale, dateStyle: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)!
        formatter.dateStyle = dateStyle
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
