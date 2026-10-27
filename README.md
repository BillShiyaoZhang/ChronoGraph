# ChronoGraph

Privacy-aware calendar sharing for iOS built with SwiftUI. Select calendars and date ranges, apply visibility rules, then export an image or maintain a dedicated iCloud calendar for others to subscribe to.

> Chinese documentation: see [README_ZH.md](README_ZH.md)

## Key Features
- **Date Ranges**: The same controls for personal and shared views: Today, the next 3 / 7 / 14 days, or custom rolling/fixed dates. Shortcuts are rolling windows that include today.
- **Calendar Selection**: Persisted multi‑calendar inclusion; first launch and Select All exclude app-generated calendars. Shared copies can still be selected manually for personal viewing.
- **Privacy Modes**: Opaque (availability + timing), Partial (title + timing), Full (title, timing, location, and notes). Calendar sharing removes disallowed fields before writing a copy.
- **Shared iCloud Calendars**: Maintain multiple independent configurations with their own sources, rolling or fixed ranges, default visibility, and occurrence/series overrides, including “Do not share”.
- **Busy / Availability Status**: Color & label badges (busy / free / tentative / unavailable) derived from `EKEventAvailability`.
- **Collapse Empty Days**: Optional UI compaction (still shows the day header) to reduce vertical length.
- **Deterministic Image Export**: WYSIWYG SwiftUI view capture (long screenshot style) with pixel‑safe scaling, solid background, light/dark color scheme consistency, JPEG file provision via a `UIActivityItemSource`.
- **Share Sheet Integration**: View, visibility, date, and Share use the same toolbar menu style. Share offers only images and calendar links; sharing rules are changed from the home status row. Images are previewed before the user sends them through the system share sheet (AirDrop, Messages, Files, etc.).
- **Resilient Rendering Path**: Prefers `ImageRenderer` (iOS 16+) with fallback to a UIKit snapshot to avoid blank output on edge layouts.
- **State Persistence**: Local privacy, dates, calendar selection, collapse preference, per-calendar viewing settings, and unconfirmed drafts are saved separately from confirmed sharing rules.
- **Calendar Authorization**: Requests full Calendar access for reading previews and maintaining explicitly enabled output calendars.

## Shared Calendars

Create a shared-calendar draft, choose source calendars and an iCloud destination account, then review the destination, dates, visibility, and estimated event changes. Explicitly turn on the initially off data-transfer consent switch before confirming creation. Later rule changes follow the same draft → review → confirm flow. Drafts can be kept or discarded without publishing. Each configuration gets its own dedicated output calendar. Original source events are not changed. Generated calendars are excluded from shared sources to prevent circular copying.

**Confirmation authorizes transmission beyond the device**: permitted fields are written through system Calendar to the selected destination account and synchronized by its provider (Apple for iCloud). A source stored only on this device or in another account is still copied to that destination; source access restrictions are not carried over. The system interface cannot reliably distinguish iCloud from other CalDAV accounts, so check the actual destination. Anyone with a public subscription link can read the calendar and forward the link; importing a link does not change system sharing permissions.

The home toolbar changes local viewing dates, sources, and detail visibility; browsing does not publish or modify confirmed sharing rules. Personal settings and each shared calendar’s viewing settings stay independent. Tap the home status row to change sharing. If the viewed dates or source calendars differ, the row opens a review with only those dates and sources proposed; the local Full display choice is never imported. The final confirmation is still required before publishing. With no date/source difference, the row opens the sharing editor. If a draft already exists, choose whether to merge the current dates and sources into it and review all changes, continue editing that draft, or cancel and keep it. Event details start read-only; changing shared visibility also requires review and confirmation. Events outside the confirmed dates or sources cannot be included merely by choosing Full.

The visibility order is occurrence override, then series override, then the configuration default. “Do not share” omits the event. Opaque preserves timing, time-zone information if present, the all-day flag, availability, and an availability placeholder title; Partial adds the title; Full adds location and notes, including notes not shown in the home list or image. Attendees, organizers, alarms, attachments, and the original event URL are not copied. Each generated event has an opaque marker URL containing random identifiers for synchronization recovery, without original source identifiers or event text.

During creation, a temporary random token in the output calendar's name lets the app recover an interruption between EventKit and local storage. The calendar is then renamed to its friendly display name. Recovery never chooses an ordinary calendar just because its name matches. If an owner manually adds attendees or an organizer to a generated event, synchronization stops with a repair error because EventKit exposes those fields as read-only; the app cannot claim to remove them.

For images from a shared view, the preview defaults to **Confirmed Shared Content**. **Current View** is an explicit alternative and shows how many included events have not been shared. Generating or sending an image does not change the subscription. Choose Save Image in the system share sheet to save the export to Photos; the app requests only permission to add photos, not to read your library.

For subscriptions, open the system Calendar app after the local update, find the dedicated iCloud calendar, and enable **Public Calendar** to copy its link, or invite specific iCloud users. Import the subscription link into ChronoGraph once and save it for that calendar. Later visits can send the saved link directly; they do not require another trip to Calendar. The link is stored locally and is handled by the selected system sharing destination when the user sends it. To replace it, choose Change Link; cancelling restores the previously saved address. Importing never reads the clipboard until the user explicitly pastes. The supplied link’s public availability and calendar identity are not verified. A recreated destination requires a newly saved link. EventKit does not provide an API for publishing the calendar or obtaining its public link; ChronoGraph provides instructions for these system steps. See [Apple's calendar sharing guide](https://support.apple.com/guide/iphone/share-icloud-calendars-iph7613c4fb/ios).

The first version maintains configurations from one device. Opening the app, source changes while it runs, and permitted background refreshes update the output; neither iOS background execution nor recipients' refresh timing is guaranteed. A successful local write does not prove iCloud upload or recipient refresh. Rolling ranges advance on the next successful update; fixed ranges retain their chosen dates. Confirmed rules also apply to later source additions and changes without asking for confirmation for each event; unconfirmed drafts are never used for updates.

Confirmed sharing configurations, overrides, identity mappings, and write intents use a dedicated local SwiftData directory excluded from device backup. They do not restore through device migration or synchronize between installations. Preferences, local viewing settings, and unconfirmed drafts use system preferences storage separately and may be retained through system backup or migration, but cannot restore maintenance of an existing output calendar. Existing output calendars can remain in iCloud after reinstalling the app or replacing the device; manage their sharing in the system Calendar app. If the original target account is unavailable, the app retains the configuration and blocks deletion or recreation until that account can be checked.

**Pause updates** leaves the existing output and sharing active. Resuming requires confirmation after a reminder about the destination account and renewed transfers. Stop sharing in the system Calendar app to prevent future access. Deleting a configuration's dedicated calendar requires confirmation and removes everything in it, including manually added events. Revoking permission does not remove existing iCloud copies. Previously downloaded data cannot be recalled. Do not manually add events to app-managed output calendars.

## Preview
(Current prototype focuses on the event list export path; weekly grid / multi‑layout roadmap items are scaffolded but not yet enabled.)

## Architecture Overview
```
ChronoGraph/
  Managers/
    CalendarManager.swift        // Authorization, calendar + event fetching, persisted prefs
    ImageExportManager.swift     // View → UIImage pipeline with scale & safety logic
    ExportedImageItemSource.swift// Share sheet integration + rich metadata
  Models/
    CalendarEvent.swift          // Immutable projection of EKEvent + availability + privacy enum
  Views/
    InAppEventListView.swift     // Grouped day list, privacy redaction, selection & detail sheet
    CalendarSelectionView.swift  // (Selection UI for included calendars)
    ContentView.swift            // Primary container, toolbars, sheets, export trigger
  ChronoGraphApp.swift           // App entry (SwiftUI App)
```
Pattern is intentionally lightweight MVVM: *Managers* (ObservableObject) expose published state; *Views* render & orchestrate interactions; *Models* keep external dependencies (EventKit) isolated at import boundaries.

### Export Pipeline (High Level)
1. User taps Share and chooses Share image. Shared images default to confirmed content; Current View requires an explicit selection.
2. `ContentView` constructs a width-locked list for the selected image scope.
3. `ImageExportManager.generateImage` measures intrinsic height, chooses safe scale (capped to 16K px dimension), and renders the preview.
4. User inspects the image and taps Send Image.
5. `ExportedImageItemSource` wraps the result, providing a temporary JPEG and metadata for the system `UIActivityViewController`.

### Privacy Model
| Mode | What User Sees | Privacy Exposure |
|------|----------------|-------------------|
| Opaque | Only time blocks labeled by availability | Reveals exact times and availability patterns |
| Partial | Title + timing; hides notes/location | Titles may contain personal details or meeting links |
| Full | Title, timing, location, and notes | May expose locations, notes, and information about others |

Image export stays on device until the user shares. When calendar sharing is explicitly enabled, permitted output fields are written into the selected calendar account and synchronized by its provider, Apple for iCloud. Preferences, sharing configurations, overrides, status, and identity mappings are stored locally; complete source events are not persisted as a separate database. See the [privacy policy](privacy-policy.md).

## Requirements
- **iOS**: 17.0+; iCloud Calendar must be enabled for calendar sharing.
- **Xcode**: A toolchain supporting the project's current synchronized groups and app icon assets. The permission/build configuration is checked with Xcode 27.
- **Frameworks**: SwiftUI, EventKit, UIKit, SafariServices, BackgroundTasks.

## Getting Started
1. Clone the repository.
2. Open `ChronoGraph.xcodeproj` (or add to a workspace).
3. Set a valid Team / signing identity. The app uses EventKit to access the user's existing iCloud account; it does not use a CloudKit container.
4. Run on a device or simulator (calendar permission prompts will appear on first access).
5. Select calendars and adjust the local view → Share image → inspect the preview → Send Image. To maintain a subscription calendar, create a draft and review/confirm its sharing rules.

### Permissions
Debug and Release merge `Config/ChronoGraph-Info.plist` with generated app metadata. Both include `NSCalendarsFullAccessUsageDescription` and the legacy `NSCalendarsUsageDescription`, describing previews/images and opt-in sanitized iCloud writes. The source plist supplies `UIBackgroundModes = [fetch]` and `BGTaskSchedulerPermittedIdentifiers = [com.shiyao-zhang.ChronoGraph.shared-calendar-refresh]`. The task identifier must match the app's registration exactly.

## Extensibility Points
| Area | Current State | Potential Enhancements |
|------|---------------|------------------------|
| Layout Variants | Single list | Week grid / heat map / timeline
| Export Formats | Long image (JPEG) | PDF, segmented pages, vector export
| Privacy Modes | 3 static | Per‑field toggles (hide location only, etc.)
| Filters | Calendar subset | Keyword, availability, all‑day toggles
| Theming | System colors | Custom palettes, dynamic accent selection

## Error Handling & Safety
- Event loading cancels stale async requests using a per‑load UUID token to avoid race overwrites.
- Export scale capped (≤16,384 px dimension) preventing CoreGraphics failures.
- Fallback snapshot path ensures non‑nil image even if `ImageRenderer` returns nil.

## Testing Notes
Basic scaffold for unit/UI tests exists (`ChronoGraphTests`, `ChronoGraphUITests`). Suggested next steps:
- Add deterministic sample events factory.
- Snapshot tests for privacy redaction.
- Performance test for very dense event ranges.

For the shared-calendar feature, follow [iCloud sharing validation](docs/iCloud-sharing-validation.md). Unit tests and simulator runs cannot establish iCloud propagation, public subscription behavior, or real background scheduling; these require the listed device checks.

## Roadmap (Short Term)
- Weekly square grid visualization.
- Multi‑range combined export (today + summary).
- Inline progress indicator during export (current boolean only).
- Localized English UI strings (currently primary strings are Chinese).

## Contributing
Pull requests welcome. For significant changes, open a discussion issue outlining:
- Problem / user story
- Proposed UI / data model adjustments
- Migration or backward compatibility considerations

## License
No explicit license file has been provided yet. Until one is added, code should be treated as "All rights reserved" by the author. Add an OSS license (e.g., MIT) before external contributions are merged.

## Acknowledgments
- Apple EventKit & SwiftUI teams for the evolving API surface.
- Community discussions around safe long‑form view rendering in SwiftUI.

---
Generated documentation draft – refine sections (screenshots, localized examples) as the feature set matures.
