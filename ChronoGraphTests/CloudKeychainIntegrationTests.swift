import Foundation
import XCTest
import Security
@testable import ChronoGraph

#if targetEnvironment(simulator)
/// Native Keychain tests touch only random account keys created by this test run.
/// No existing session is enumerated or read, and no authentication/network is used.
@MainActor
final class CloudKeychainIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CHRONOGRAPH_EVENTKIT_INTEGRATION"] == "1" else {
            throw XCTSkip("Native Keychain tests require an explicitly opted-in, dedicated Simulator.")
        }
        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains("-cloud-signed-in-fixtures"),
                       "Native Keychain tests must not be redirected to the UI fixture's memory store.")
    }

    func testNativeSyntheticSessionRoundTripsAndUpdates() throws {
        let key = uniqueKey("session")
        let first = Data((0..<32).map { UInt8($0) })
        let replacement = Data(repeating: 0xA7, count: 32)
        XCTAssertNil(CloudSecureStore.read(key))
        try CloudSecureStore.save(first, key: key)
        defer { CloudSecureStore.remove(key) }

        XCTAssertEqual(CloudSecureStore.read(key), first)
        try CloudSecureStore.save(replacement, key: key)
        XCTAssertEqual(CloudSecureStore.read(key), replacement)
        XCTAssertNotEqual(CloudSecureStore.read(key), first)
    }

    func testNativeAccountNamespacesRemainIsolated() throws {
        let namespace = uniqueKey("accounts")
        let firstKey = namespace + ".account-a.session"
        let secondKey = namespace + ".account-b.session"
        let first = Data(repeating: 0x11, count: 32)
        let second = Data(repeating: 0x22, count: 32)
        XCTAssertNil(CloudSecureStore.read(firstKey))
        XCTAssertNil(CloudSecureStore.read(secondKey))
        try CloudSecureStore.save(first, key: firstKey)
        defer { CloudSecureStore.remove(firstKey) }
        try CloudSecureStore.save(second, key: secondKey)
        defer { CloudSecureStore.remove(secondKey) }

        XCTAssertEqual(CloudSecureStore.read(firstKey), first)
        XCTAssertEqual(CloudSecureStore.read(secondKey), second)
        CloudSecureStore.remove(firstKey)
        XCTAssertNil(CloudSecureStore.read(firstKey))
        XCTAssertEqual(CloudSecureStore.read(secondKey), second)
    }

    func testNativeRemovalIsIdempotentAndRemovesTheExactItem() throws {
        let key = uniqueKey("remove")
        XCTAssertNil(CloudSecureStore.read(key))
        try CloudSecureStore.save(Data(repeating: 0x33, count: 32), key: key)
        defer { CloudSecureStore.remove(key) }

        CloudSecureStore.remove(key)
        CloudSecureStore.remove(key)
        XCTAssertNil(CloudSecureStore.read(key))
        var output: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(exactQuery(key) as CFDictionary, &output), errSecItemNotFound)
    }

    func testNativeAccessibilityIsDeviceOnlyAndSurvivesAnUpdate() throws {
        let key = uniqueKey("accessibility")
        XCTAssertNil(CloudSecureStore.read(key))
        try CloudSecureStore.save(Data(repeating: 0x44, count: 32), key: key)
        defer { CloudSecureStore.remove(key) }

        try assertDeviceOnlyAccessibility(key)
        try CloudSecureStore.save(Data(repeating: 0x55, count: 32), key: key)
        try assertDeviceOnlyAccessibility(key)
    }

    private func uniqueKey(_ suffix: String) -> String {
        "simulator-validation." + UUID().uuidString + "." + suffix
    }

    private func exactQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.shiyao-zhang.ChronoGraph.cloud",
         kSecAttrAccount as String: key,
         kSecMatchLimit as String: kSecMatchLimitOne]
    }

    private func assertDeviceOnlyAccessibility(_ key: String) throws {
        var query = exactQuery(key)
        query[kSecReturnAttributes as String] = true
        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        XCTAssertEqual(status, errSecSuccess)
        let attributes = try XCTUnwrap(output as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)
    }
}
#endif
