# ChronoGraph

Privacy‑aware calendar activity exporter for iOS built with SwiftUI. ChronoGraph lets you select calendars & date ranges, apply privacy redaction levels, then export a high‑resolution, long (vertical) image of your recent schedule for sharing.

> Chinese documentation: see [README_ZH.md](README_ZH.md)

## Key Features
- **Date Ranges**: Today, last 3 / 7 / 14 days (extensible enum in `CalendarManager.DateRange`).
- **Calendar Selection**: Persisted multi‑calendar inclusion; first launch defaults to all available event calendars.
- **Privacy Modes**: Opaque (hide all details), Partial (title + time), Full (all fields). Redaction handled entirely in view layer; raw data never leaves device.
- **Busy / Availability Status**: Color & label badges (busy / free / tentative / unavailable) derived from `EKEventAvailability`.
- **Collapse Empty Days**: Optional UI compaction (still shows the day header) to reduce vertical length.
- **Deterministic Image Export**: WYSIWYG SwiftUI view capture (long screenshot style) with pixel‑safe scaling, solid background, light/dark color scheme consistency, JPEG file provision via a `UIActivityItemSource`.
- **Share Sheet Integration**: Direct system share after generation (AirDrop, Messages, Files, etc.).
- **Resilient Rendering Path**: Prefers `ImageRenderer` (iOS 16+) with fallback to a UIKit snapshot to avoid blank output on edge layouts.
- **State Persistence**: `UserDefaults` keys: privacy mode, date range, selected calendar identifiers, collapse preference (separate `@AppStorage`).
- **Adaptive Authorization**: Uses new iOS 17+ full access API when available; falls back seamlessly for iOS 16.

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
    LiquidContentView.swift      // Primary container, toolbars, sheets, export trigger
  ChronoGraphApp.swift           // App entry (SwiftUI App)
```
Pattern is intentionally lightweight MVVM: *Managers* (ObservableObject) expose published state; *Views* render & orchestrate interactions; *Models* keep external dependencies (EventKit) isolated at import boundaries.

### Export Pipeline (High Level)
1. User taps share button.
2. `LiquidContentView` constructs an identical, width‑locked list view (ensures layout parity).
3. `ImageExportManager.generateImage` measures intrinsic height, chooses safe scale (capped to 16K px dimension), renders.
4. `ExportedImageItemSource` wraps result, providing temp JPEG and metadata for better previews.
5. System `UIActivityViewController` presented.

### Privacy Model
| Mode | What User Sees | Data Leakage Risk |
|------|----------------|-------------------|
| Opaque | Only time blocks labeled by availability | Minimal |
| Partial | Title + timing; hides notes/location | Low |
| Full | All accessible fields | Depends on event content |

Raw events are never uploaded; export stays on device until the user shares.

## Requirements
- **iOS**: 16.0+ (iOS 17+ enables `requestFullAccessToEvents()` path; project designed to stay source‑compatible forward)
- **Xcode**: 15+ (Swift 5.9+). For 2025 toolchains, Xcode 17 recommended.
- **Frameworks**: SwiftUI, EventKit, UIKit (for export + share), SafariServices (privacy policy sheet).

## Getting Started
1. Clone the repository.
2. Open `ChronoGraph.xcodeproj` (or add to a workspace).
3. Set a valid Team / signing identity (no special capabilities beyond calendar usage required).
4. Run on a device or simulator (calendar permission prompts will appear on first access).
5. Select calendars & adjust privacy mode → tap export icon.

### Permissions
Add the required usage description in `Info.plist` if not already present:
- `NSCalendarsUsageDescription` (Why you need read access.)

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
