import SwiftUI

/// Range changes are drafts until the shared calendar review is confirmed.
struct SharedCalendarRangeEditorView: View {
    let profile: SharedCalendarProfile

    var body: some View {
        SharedCalendarEditorView(profile: profile, defaultSourceIDs: profile.sourceCalendarIDs,
            defaultPrivacyMode: profile.privacyMode, opensRangeEditor: true)
    }
}
