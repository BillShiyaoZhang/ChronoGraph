# Privacy Policy

Last updated: October 28, 2026.

ChronoGraph processes calendar selection, visibility rules, previews, and images on your device. An optional cloud collaboration beta requires separate login and consent. The app has no behavior analytics or advertising trackers. **Sharing transfers data beyond your device:** iCloud mirroring writes confirmed copies to your selected calendar account, while cloud collaboration uploads separately selected fields to the configured ChronoGraph server. Neither authorization substitutes for the other.

## Optional Cloud Collaboration

The default API is `https://agent-communication.online/chronograph/`, hosted on Alibaba Cloud; another HTTPS endpoint may be configured before login. Calendar permission alone does not enable uploads. After login, explicitly choose sources and field levels and confirm. Uploads include calendar names, random or irreversibly mapped identifiers, start/end times, timezone, all-day flags and availability. Partial adds titles; Full adds location and notes. Original URLs, attendees, organizers, alarms and attachments are excluded. The initial window covers the preceding seven days and following ninety days.

**Cloud upload is independent of per-event iCloud sharing rules.** An event excluded from an iCloud mirror may still belong to a separately selected cloud source. Review cloud sources and field levels. Uploading does not automatically grant others access. Account sharing uses separately created grants; anyone holding a public ICS link can read its permitted fields and forward it.

You may register with an invitation, username and password. The server stores your normalized username and a salted Argon2id password hash; the app does not save your password. Invitation codes are stored as digests with expiry and usage limits. Changing or administratively resetting a password revokes existing sessions. Password recovery currently requires contacting the server administrator. Where enabled, Apple verifies Apple login and the server never receives your Apple Account password. The server stores an account identifier, random device identifiers and necessary session records. Session credentials use device Keychain and server-side digests. The server also stores sync times, coverage, grants, meeting titles/times, participant accounts, responses and calendar-write tasks for matching and coordination. The server processes allowed uploaded data; HTTPS and access control are not end-to-end encryption.

You may stop sync, remove sources, revoke links/access, sign out or delete the cloud account. Stopping sync or signing out does not delete uploaded data. Removing a source deletes its events and grants. Account deletion removes password credentials, private sources, devices and sessions and pseudonymizes coordination records involving others. It cannot recall downloaded copies or revoke Apple's separate app authorization automatically. Backups may retain earlier data until expiry; relevant deletions must be reapplied after restoration. The initial deployment retains at most fourteen database dumps on the same server; off-host backup still needs configuration.

Device/background execution can be delayed; the displayed sync time is the last successful upload. App agreement and system-calendar insertion are separate. Initial insertion requires choosing a calendar; later reconciliation touches only app-created, unmodified projections and preserves manual edits for review. Normal request logs exclude subscription tokens and event bodies, while necessary network metadata is processed. Images remain on-device and are not automatically uploaded.

## Calendar Access and Local Browsing

The app requests full Calendar access to read events for previews and images and, when you enable sharing, to create and maintain dedicated output calendars. It does not modify the original source events. It does not request access to Reminders, Contacts, or your device's location; a location already written in an event is calendar content. Granting Calendar access does not itself create a shared calendar or publish events.

Changing viewing dates, source calendars, or local detail visibility on the home screen, or keeping an editing draft, does not change confirmed sharing rules. Creating a shared calendar, changing its rules, or changing the shared visibility of an occurrence or series requires review and explicit confirmation. Confirmation authorizes ongoing maintenance under those rules, rather than a one-time transfer of only the events currently previewed.

You choose each shared calendar's source calendars, rolling or fixed date range, and default visibility. You can override visibility for an individual occurrence or a recurring series, or exclude it from sharing. Each shared calendar has its own settings. The first version maintains these settings from one device; the app does not synchronize sharing configurations between installations.

## How Shared Data Is Transmitted

1. The app reads events from your selected source calendars and date range through the system Calendar interface, then applies visibility rules on your device.
2. After your confirmation, the app creates or updates a dedicated output calendar through the system Calendar interface. **Permitted fields are copied to the selected destination account even when the source event is stored only on your device or belongs to another account.** Source-calendar access restrictions are not carried over to the copy.
3. The destination provider synchronizes output; Apple handles iCloud. This mirror path uses system account authorization and neither receives your iCloud password nor uploads to the ChronoGraph server. Optional cloud upload is enabled separately as described above. The system interface cannot reliably distinguish iCloud from other CalDAV accounts, so verify the destination before confirming.
4. After you invite people or enable Public Calendar in the system Calendar app, others can read the output according to those sharing settings. **Anyone with a public subscription link can access the calendar, and the link can be forwarded.** The app does not enable Public Calendar on your behalf and cannot restrict who holds its public link.

The shared calendar's name is also written to the destination account and may appear in subscribers' calendars. Avoid putting information you do not intend to share in its name. Account synchronization, storage, and recipients' services are subject to those services and their policies. See [Apple's iCloud calendar sharing guide](https://support.apple.com/guide/iphone/share-icloud-calendars-iph7613c4fb/ios).

## What a Shared Calendar Contains

Visibility is applied to the data before it is written to the output calendar:

| Visibility | Fields written to the output |
|---|---|
| Opaque | Start and end time, time-zone information if present, all-day flag, availability, and an availability placeholder title |
| Partial | The timing and availability fields above, plus the event title |
| Full | The fields above, plus event location and notes |
| Do not share | No copy of the event; an existing copy is removed on a subsequent successful update |

Opaque still reveals exact times and availability patterns; it does not make an event anonymous. Titles, locations, and notes you choose to share may contain personal information, contact details, meeting links, or information about other people. Review the details before confirming. Full calendar output includes notes even when they are not shown in a home-screen list or exported image.

The app does not copy attendees, organizers, alarms, attachments, or the source event's URL. Output events also contain a generated opaque marker URL used to identify app-managed copies and recover synchronization; it contains random identifiers, not the source event's title, notes, account credentials, or source identifier. Recurring events are maintained as individual occurrence copies within the date range; original recurrence rules are not copied.

If attendees or an organizer are manually added to an output event, synchronization stops and requests repair because EventKit does not let the app remove those read-only fields. Existing data is not automatically withdrawn by that error. During calendar creation, a temporary random name marker supports recovery across interrupted local writes; the app then applies the friendly calendar name.

## Ongoing Updates and Your Controls

After confirmation, the app keeps copies updated using the confirmed sources, date range, default visibility, and overrides. Source additions, changes, and deletions, and a rolling range advancing with time, can change the output without asking you to confirm each individual event again. Unconfirmed rule edits and drafts are not used for background updates. Rules confirmed while updates are paused are saved and used to maintain the output after updates resume. Updates run when the app is open, after source changes while it runs, and when iOS permits background work. Neither iCloud propagation nor another person's subscription refresh is immediate or guaranteed at a fixed interval.

You can change or remove source selections, date ranges, and visibility overrides; pause updates; close sharing in the system Calendar app; or delete a dedicated output calendar after confirmation. Deleting that calendar deletes everything in it, including events added there manually. Use a separate dedicated calendar for each shared configuration.

**Pausing updates only stops future maintenance; it does not withdraw existing contents or disable system sharing.** Revoking Calendar permission in Settings > Privacy & Security > Calendars stops the app from reading and maintaining calendars, but does not remove copies already in the destination account. To stop others from receiving further updates, change sharing settings or delete the output calendar in the system Calendar app. Previously downloaded, exported, forwarded, or cached copies cannot be recalled.

More restrictive visibility, removing events, or deleting a calendar requires a successful write to the destination account and refreshes by the service and subscribers. During failures or delays, recipients may still see the previous contents. Revoking a public link or deleting a shared calendar cannot erase data already received. See [Apple's instructions for stopping calendar sharing](https://support.apple.com/guide/icloud/mm6b1a8f9f/icloud) and [its guidance on existing subscribed copies](https://support.apple.com/guide/personal-safety/ips339be2c38/web).

## Local Storage, Subscription Links, and Images

The app stores preferences, shared-calendar configurations, visibility overrides, synchronization status, identity mappings, pending write intents, viewing settings, and unconfirmed drafts on your device. Confirmed sharing state and imported subscription links use a dedicated local directory excluded from device backup. These data do not restore through device migration or synchronize between installations through the app. Preferences, viewing settings, and unconfirmed drafts use system preferences storage separately and may be retained through system backup or migration; they cannot on their own restore maintenance of an existing output calendar.

The app does not persist a separate database of complete source events. Source content is read into memory for the current operation; selected output fields are persisted in the output calendar. Account synchronization and other device data remain subject to your operating system and account settings. Reinstalling the app or replacing a device does not remove an output calendar already synchronized to the destination account. Manage its sharing through the system Calendar app; a new installation does not automatically resume maintenance from a calendar name.

Deleting a shared configuration does not guarantee removal of every local record. Some identity metadata and a previously imported link may remain in app storage until the app's data is removed. They do not by themselves restart synchronization. System backups and data held by account providers remain subject to their respective settings and retention policies.

You can obtain a public subscription link from the system Calendar app and explicitly paste or type it into ChronoGraph for later sending. The link is stored on your device and bound to the corresponding output calendar. The app checks only its address format; it does not fetch the address, verify the calendar's identity or public availability, or read your clipboard automatically. Importing or saving a link does not enable, disable, or change system Calendar sharing permissions. A public link provides read access, so send it only to people you intend to allow access.

Exported images are generated on your device and may be stored as temporary image files for system sharing. Images from a shared view default to confirmed shared content; explicitly selecting Current View can include events that are not part of the subscription. Check the preview before sending. When you explicitly send an image or subscription link, the app passes that content to the system sharing flow, where your selected app, service, or recipient handles it. We do not automatically upload images or links. Sending an image does not change shared-calendar rules.

You can also choose Save Image in the system share sheet to add an exported image to Photos. The system requests add-only permission when needed; ChronoGraph does not read or browse your photo library. Photos manages the saved image. If iCloud Photos is enabled, it can synchronize the image to iCloud and your other devices according to your system settings; this does not upload it to a developer-operated server. See [Apple’s iCloud Photos guide](https://support.apple.com/108782).

## Diagnostics and Changes

Apart from explicitly enabled cloud collaboration, the app does not upload personal events, behavior analytics or diagnostics. System account sync, backup and diagnostics follow system settings and provider policies. Opening an online policy or help page sends a browser request governed by that site's policy, without attaching event content. Changes to access or transmission will be described before taking effect.

## Contact

For privacy questions, email zhangshiyao_ZSY@outlook.com. We use your message to respond to your inquiry.

Chinese version: see [隐私政策](./隐私政策.md).
