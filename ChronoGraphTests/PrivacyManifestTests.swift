import Foundation
import Testing

struct PrivacyManifestTests {
    // Validate the shipped app resource rather than a source-tree file. This also
    // catches accidentally removing the manifest from the target's resources.
    private func bundledManifest() throws -> [String: Any] {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func bundledManifestDeclaresTheAppsPrivatePreferencesUse() throws {
        let manifest = try bundledManifest()
        let accessed = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let preferences = try #require(accessed.first {
            $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
        })
        let reasons = try #require(preferences["NSPrivacyAccessedAPITypeReasons"] as? [String])
        #expect(reasons.contains("CA92.1"))
    }

    @Test func optionalCloudCollectionIsDisclosedWithoutTracking() throws {
        let manifest = try bundledManifest()
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [String])?.isEmpty == true)
        let collected = try #require(manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        for type in ["NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeDeviceID", "NSPrivacyCollectedDataTypeOtherUserContent"] {
            let entry = try #require(collected.first { $0["NSPrivacyCollectedDataType"] as? String == type })
            #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            let purposes = try #require(entry["NSPrivacyCollectedDataTypePurposes"] as? [String])
            #expect(purposes == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
        }
    }
}
