import Foundation
import Testing
@testable import ChronoGraph

struct SubscriptionLinkStoreTests {
    private func profile(id: UUID = UUID(), target: String? = "target") -> SharedCalendarProfile {
        SharedCalendarProfile(id: id, name: "Test", sourceCalendarIDs: ["source"],
            targetSourceID: "account", targetCalendarID: target)
    }

    @Test func onlyExplicitCalendarLinkSchemesWithHostsAreAccepted() throws {
        #expect(try SubscriptionLinkStore.validatedURL(" webcal://calendar.example.com/feed.ics?token=secret \n").scheme == "webcal")
        #expect(try SubscriptionLinkStore.validatedURL("HTTPS://calendar.example.com/feed.ics").scheme == "https")
        for value in ["", "http://calendar.example.com/feed.ics", "javascript:alert(1)",
                      "file:///calendar.ics", "webcal:calendar.ics", "https:///feed.ics",
                      "https://person:password@calendar.example.com/feed.ics"] {
            #expect(throws: SubscriptionLinkError.invalidURL) { try SubscriptionLinkStore.validatedURL(value) }
        }
    }

    @MainActor @Test func targetAndProfileBindingsNeverReuseAnotherLink() throws {
        let store = try SubscriptionLinkStore(inMemory: true)
        let original = profile()
        let saved = try store.save("webcal://calendar.example.com/first.ics", for: original)
        #expect(try store.link(for: original) == saved)
        #expect(try store.link(for: profile(target: original.targetCalendarID)) == nil)
        var recreated = original
        recreated.targetCalendarID = "replacement-target"
        #expect(try store.link(for: recreated) == nil)
        #expect(try store.link(for: original) == nil)
        #expect(throws: SubscriptionLinkError.missingTarget) {
            try store.save("https://calendar.example.com/new.ics", for: profile(target: nil))
        }
    }

    @MainActor @Test func linksPersistInDirectoryExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = profile()
        let first = try SubscriptionLinkStore(storageDirectory: directory)
        let saved = try first.save("https://calendar.example.com/feed.ics", for: original)
        let restored = try SubscriptionLinkStore(storageDirectory: directory)
        #expect(try restored.link(for: original) == saved)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @MainActor @Test func separateSheetStoresPreserveOtherProfilesAndPersistTargetInvalidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstSheet = try SubscriptionLinkStore(storageDirectory: directory)
        let secondSheet = try SubscriptionLinkStore(storageDirectory: directory)
        let firstProfile = profile(target: "first-target")
        let secondProfile = profile(target: "second-target")
        let firstLink = try firstSheet.save("https://calendar.example.com/first.ics", for: firstProfile)
        let secondLink = try secondSheet.save("webcal://calendar.example.com/second.ics", for: secondProfile)
        #expect(try secondSheet.link(for: firstProfile) == firstLink)
        #expect(try firstSheet.link(for: secondProfile) == secondLink)
        var recreated = firstProfile
        recreated.targetCalendarID = "recreated-target"
        #expect(try secondSheet.link(for: recreated) == nil)
        #expect(try firstSheet.link(for: firstProfile) == nil)
        #expect(try firstSheet.link(for: secondProfile) == secondLink)
    }
}
