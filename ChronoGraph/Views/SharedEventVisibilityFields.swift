import SwiftUI

/// The same occurrence/series and inheritance controls serve both publishing channels.
struct SharedEventVisibilityFields: View {
    let isRecurring: Bool
    let occurrenceOverride: SharedVisibility?
    let seriesOverride: SharedVisibility?
    let defaultVisibility: SharedVisibility
    @Binding var entireSeries: Bool
    @Binding var selection: String
    var identifierPrefix = "sharing.event"

    private var inheritsSeries: Bool { !entireSeries && isRecurring && seriesOverride != nil }
    private var inheritedVisibility: SharedVisibility { inheritsSeries ? seriesOverride ?? defaultVisibility : defaultVisibility }

    var body: some View {
        Section {
            if isRecurring {
                Picker("sharing.override.scope", selection: $entireSeries) {
                    Text("sharing.override.occurrence").tag(false)
                        .accessibilityIdentifier(identifierPrefix + ".scope.occurrence")
                    Text("sharing.override.series").tag(true)
                        .accessibilityIdentifier(identifierPrefix + ".scope.series")
                }
                .accessibilityIdentifier(identifierPrefix + ".scope")
                .onChange(of: entireSeries) { _, series in
                    selection = (series ? seriesOverride : occurrenceOverride)?.rawValue ?? "inherit"
                }
            }
            Picker("sharing.override.visibility", selection: $selection) {
                (Text(inheritsSeries ? LocalizedStringKey("sharing.visibility.inheritSeries") : LocalizedStringKey("sharing.visibility.inheritCalendar"))
                 + Text(" · ") + Text(inheritedVisibility.localizedKey))
                    .tag("inherit").accessibilityIdentifier(identifierPrefix + ".visibility.inherit")
                ForEach(SharedVisibility.allCases) { visibility in
                    Text(visibility.localizedKey).tag(visibility.rawValue)
                        .accessibilityIdentifier(identifierPrefix + ".visibility." + visibility.rawValue)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } header: { Text("sharing.override.visibility") }
        footer: { Text("sharing.visibility.priority") + Text("\n") + Text("sharing.draft.localOnly") }
    }
}

struct SharedEventOriginalSection: View {
    let event: SharedEventPreview
    var identifierPrefix = "sharing.event.original"

    var body: some View {
        Section("sharing.events.source") {
            VStack(alignment: .leading, spacing: 8) {
                Text(event.title).font(.headline).accessibilityIdentifier(identifierPrefix + ".title")
                SharedEventTimeView(start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            if event.source?.location?.isEmpty == false || event.source?.notes?.isEmpty == false {
                DisclosureGroup("detail.info") {
                    if let location = event.source?.location, !location.isEmpty { Label(location, systemImage: "location") }
                    if let notes = event.source?.notes, !notes.isEmpty { Text(notes) }
                }
                .accessibilityIdentifier(identifierPrefix + ".details")
            }
        }
    }
}
