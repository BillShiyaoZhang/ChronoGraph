# Cloud Simulator validation

The signed-in cloud UI tests use `-cloud-signed-in-fixtures` in a DEBUG build. The real client serializes requests into an in-process URLProtocol transport. It intercepts all requests from that client, accepts only `https://chronograph-ui.invalid/chronograph`, and rejects other origins. Secure storage is in memory, cloud preferences use a fresh private defaults suite, and source calendar reads use synthetic events. These tests do not authenticate with Apple, reach the deployed API, read personal calendars, or write meeting events into EventKit.

## Receiver sharing workflow (2026-10-28)

Received cloud calendars can now be selected from the home screen's schedule menu → Choose Calendars to Display, or Settings → Calendars. The selector combines local calendar groups with a separate received-cloud section. Selections are stored per server/account on this device; received event contents stay in memory. The personal overview merges selected sources, labels each cloud row with its owner/source, and follows the home date range and display privacy. The shared calendar editor continues to use local source calendars.

The client reapplies opaque/partial/full grants before rendering, so choosing Full locally cannot restore excluded fields. Details are read-only and close when their current projection disappears or changes. Logout/account changes clear received rows. Coverage gaps, expired snapshots and read failures have explicit source status; unknown dates do not appear as an empty calendar. Pull-to-refresh and foreground entry refresh cloud metadata and events. Image export uses the same projected fields and preserves incomplete-data notices. Browsing cloud calendars does not require EventKit access; the home screen still offers the local authorization/settings action.

`CloudSharedScheduleTests` covers source-scoped event IDs, field permission limits, partial coverage, stale sources, failures, and suspended requests across dates, permissions and accounts. `CloudSharedScheduleUITests` uses the `cloud-home*` synthetic fixture scenarios for mixed local/received display, date changes, retry/logout, revoked access and foreground permission downgrade while full details are open. The production API and the user's manual-test pairing link are not accessed by these tests.

The home-display validation passed 38 focused logic tests and seven unique UI journeys on iPhone 17/iOS 26.5, including existing incoming-link and personal-image sharing. The initial UI run had two test locator failures (returning from the cloud child page to Settings, and treating a read-only Label leaf as hittable); both passed the focused rerun. Debug and Release builds passed, all result bundles were retained, and the dedicated Simulator was deleted.

A user-provided pairing link was tested over production HTTPS with two disposable invitation/password accounts. The 31 requests verified the browser landing instructions, authenticated redemption, idempotent redemption by the same recipient, rejection of a second recipient, source listing, opaque event projection, and two-/three-person availability using the real shared source. The receiver calendars were synthetic and empty; the seven-day search returned six free windows fitting a 30-minute meeting. No owner source upload or owner response was submitted.

A temporary proposal including the owner remained pending, and premature host confirmation returned `responses_incomplete`; no owner calendar projection task was created. Acceptance, confirmation, durable tasks and cancellation were separately completed between the two disposable accounts. Test accounts, grants and meeting records were removed, and the test registration invitation was revoked. The consumed original link was revoked, and an unused replacement with identical privacy and expiry was saved in an owner-only file under the Git-ignored `.local-secrets/` directory. Raw links and private calendar contents are excluded from validation reports.

The dedicated iPhone 17/iOS 26.5 UI run covers incoming links, candidate selection/proposal creation, pending responses, guest response controls, and host confirmation/cancellation. The first run passed four journeys and exposed a test-helper focus error when it tapped an empty input twice while the keyboard changed the Form layout. The helper now waits for the keyboard, only adjusts the cursor for existing text, and prefers the explicit keyboard Done action. The affected incoming-link and candidate journeys both passed the focused rerun with no skips, completing all five selected journeys. Both result bundles and the initial failure are retained in the validation report.

The browser landing currently shows English plain-text instructions. It does not open the app automatically. Receivers must log in to the same server, paste the link under the cloud workspace's incoming calendars, and upload their own calendar before searching. Invitations require app refresh, and reciprocal sharing is needed for the other person to initiate a search. The app lists shared sources but does not provide a separate timeline of their events.

## Calendar snapshot timezone regression (2026-10-28)

The original fixtures used IANA zones and missed Foundation's fixed-offset names (`GMT+0800`, `GMT+0530`). The event API now accepts bounded Foundation offsets and uses the same resolver for all-day ICS dates. The production user confirmed synchronization recovered after the server update; no account recreation or source deletion was needed.

`CloudEventKitIntegrationTests/testNativeReaderSerializesFixedOffsetZonesAndAllDayDates` creates a dedicated local calendar on a disposable Simulator, reads real EventKit values, projects only opaque fields and attaches `native-fixed-offset-snapshot.json`. That exact Swift-generated body was accepted by the production API in a temporary account. Readback, idempotent retry, all-day ICS dates and preservation of prior coverage after an invalid zone all passed; the account and its invite were cleaned up.

The regression run passed 84 backend tests, 120 Simulator logic/Keychain tests and the native EventKit case, with no skips. Debug and Release builds passed. Wire dates retain six fractional digits to match server microsecond precision; intervals that collapse at that precision are rejected locally. Structured 422 feedback exposes only known field labels and event indices, never rejected event content or credentials.

## Password accounts

The default Personal Team build supports username/password sessions while `CHRONOGRAPH_APPLE_SIGN_IN=NO`. Apple-only sessions remain dormant. `CloudPasswordAuthenticationTests` checks the server/client username and password boundaries, account-scoped device IDs and backward-compatible provider decoding. The native Keychain suite uses random test keys on an explicitly opted-in Simulator and removes them afterward.

`CloudPasswordAuthenticationUITests` uses `-cloud-password-fixtures`, with `password-fresh` or `password-restored`. Restored sessions pass through the production decoding/restoration path with an isolated memory store. Cases cover invalid-invite retry, wrong-password retry, login/logout/relogin, password change with a wrong current password, and calendar upload remaining disabled until separate consent. Set `CHRONOGRAPH_AUTH_TEXT_SIZE=UICTContentSizeCategoryAccessibilityXXXL` and `CHRONOGRAPH_AUTH_STYLE=Dark` to repeat the same paths on iPad with large text.

The iOS 26.1 Simulator can substitute an `Automatic Strong Password cover view text` overlay for new-password input, corrupting injected test text. On an explicitly disposable Simulator, `CHRONOGRAPH_MANUAL_PASSWORD_SIMULATOR=1` prepares manual entry by opening Settings → General → AutoFill & Passwords and disabling password AutoFill on that device. This option never changes a physical device and should not be used with a personal Simulator. Production fields retain Apple's recommended `newPassword` content type; real password-manager generation/fill remains a device acceptance check. See [Apple's input configuration](https://developer.apple.com/documentation/security/enabling-password-autofill-on-a-text-input-view).

The deployed password service was additionally exercised over real HTTPS using three temporary accounts: six mutual calendar grants, three opaque busy snapshots, merged common-time search, participant responses, host confirmation, durable tasks and cancellation. The verification script deleted the synthetic accounts and revoked its invite. This checks server coordination; calendar writes and real-device background delivery remain separate acceptance steps. Registration invitations are local private operator files, excluded from Git and test artifacts.

`CloudSignedInWorkspaceUITests` covers consent and upload privacy, source/account deletion, nickname updates, grants/feed revocation, incoming links, grouped people, candidate invalidation, proposing, responding, confirmation/cancellation, stale data, conflicts, empty results, expired sessions, recoverable server failures, and logout while revocation is delayed or fails. Screenshot attachments are retained in the test result bundle. `CloudDatePresentationTests` verifies declared timezone wall times, date boundaries and daylight-saving transitions.

`CloudWorkspaceMatrixUITests` has three focused presentation journeys: compact screen with the largest accessibility text category, dark guest responses, and landscape candidate/meeting screens. Choose the compact Simulator as the test destination; the tests do not change the Simulator model. The matrix runner accepts these environment overrides:

| Variable | Values/default |
| --- | --- |
| `CHRONOGRAPH_MATRIX_LANGUAGE` | `zh-Hans` by default; also supports `en` |
| `CHRONOGRAPH_MATRIX_LOCALE` | `zh_CN` or `en_US`, inferred from language |
| `CHRONOGRAPH_MATRIX_ORIENTATION` | `portrait`, `landscapeLeft`, `landscapeRight`; otherwise the journey default |
| `CHRONOGRAPH_MATRIX_STYLE` | `Light` or `Dark`; otherwise the journey default |
| `CHRONOGRAPH_MATRIX_TEXT_SIZE` | Apple content-size category, such as `UICTContentSizeCategoryAccessibilityXXXL` |

Presentation tests check reachability and record screenshots. Visual inspection of those screenshots is still required to confirm wrapping, contrast, and truncation. Their presence in this repository does not imply a successful run; retain the actual `.xcresult` when reporting results.

Known gap: cloud labels, privacy disclosures, local errors and manager notices currently use Chinese literals. Selecting English changes the surrounding app language but does not fully translate cloud screens. The date helper accepts an explicit locale; its current cloud call sites use the system locale rather than the app's independently selected language. Apple sign-in entitlement/real authentication, production API interoperability, and native calendar projection need separate validation.
