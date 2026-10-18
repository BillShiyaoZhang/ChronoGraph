# Privacy Policy

Last updated: October 18, 2026.

ChronoGraph processes calendar selection, visibility rules, previews, and image rendering on your device. We operate no calendar backend, analytics service, or advertising tracker. If you explicitly enable a shared calendar, the app writes selected event copies into a dedicated calendar in your chosen iCloud account. Apple then synchronizes that calendar, and you control its sharing in the system Calendar app.

## Calendar Access

The app requests full Calendar access to read events for previews and images and, when you enable sharing, to create and maintain dedicated output calendars. It does not modify the original source events. It does not request access to Reminders, Contacts, or your device's location; a location already written in an event is calendar content.

You choose each shared calendar's source calendars, rolling or fixed date range, and default visibility. You can override visibility for an individual occurrence or a recurring series, or exclude it from sharing. Each shared calendar has its own settings. The first version maintains these settings from one device; they are not synchronized between installations.

## What a Shared Calendar Contains

Visibility is applied to the data before it is written to the output calendar:

| Visibility | Fields written to the output |
|---|---|
| Opaque | Start and end time, all-day flag, availability, and an availability placeholder title |
| Partial | The timing and availability fields above, plus the event title |
| Full | The fields above, plus event location and notes |
| Do not share | No copy of the event |

The app does not copy attendees, organizers, alarms, attachments, or the source event's URL. Text you choose to share in titles or notes may itself contain personal details or meeting links. Output events also contain a generated opaque marker URL used to identify app-managed copies and recover synchronization; it contains random identifiers, not the source event's title, notes, account credentials, or source identifier.

If attendees or an organizer are manually added to an output event, synchronization stops and requests repair because EventKit does not let the app remove those read-only fields. Existing data is not automatically withdrawn by that error. During calendar creation, a temporary random name marker supports recovery across interrupted local writes; the app then applies the friendly calendar name.

The copies are stored in your chosen iCloud calendar and handled by Apple under its policies. If you publish that calendar, anyone with its subscription link can access its shared contents. If you invite specific people instead, their access is controlled through system Calendar sharing settings. ChronoGraph does not receive your iCloud password or publish a subscription link on your behalf.

## Local Storage and Image Export

The app stores preferences, shared-calendar configurations, visibility overrides, synchronization status, identity mappings, and pending write intents on your device. Sharing state uses a dedicated local SwiftData directory excluded from device backup; those configurations do not restore through device migration or synchronize between installations. The app does not persist a separate database of complete source events. Source content is read into memory for the current operation; selected output fields are persisted in the output calendar. Account synchronization and other device data remain subject to your operating system and account settings.

Reinstalling the app or replacing a device does not remove an output calendar already synchronized to iCloud. You must manage its sharing through the system Calendar app; the new installation does not automatically resume maintenance from a calendar name.

Exported images are generated on your device. An image leaves the app when you choose a destination in the system share sheet. We do not automatically upload images.

## Your Controls and Existing Copies

You can change or remove source selections, date ranges, and visibility overrides; pause updates; close sharing in the system Calendar app; or delete a dedicated output calendar after confirmation. Deleting that calendar deletes everything in it, including any events added there manually. Use a separate dedicated calendar for each shared configuration.

Pausing updates only stops future maintenance; it does not withdraw existing calendar contents or disable system sharing. Revoking Calendar permission in Settings > Privacy & Security > Calendars stops the app from reading and maintaining calendars, but does not remove copies already in iCloud. To stop others from receiving further updates, change sharing settings or delete the output calendar in the system Calendar app. Previously downloaded, exported, or cached copies cannot be recalled.

Updates run when the app is open and, when iOS permits, in the background. Neither iCloud propagation nor another person's subscription refresh is immediate or guaranteed at a fixed interval. More restrictive visibility takes effect in the output after a successful update and in recipients' calendars when they refresh; it cannot erase previously received data.

## Diagnostics and Changes

The app does not send personal event content, behavior analytics, or diagnostic uploads to us. Future changes to data access or transmission will be described in the app and this policy before they take effect.

## Contact

For privacy questions, email zhangshiyao_ZSY@outlook.com. We use your message to respond to your inquiry.

Chinese version: see [隐私政策](./隐私政策.md).
