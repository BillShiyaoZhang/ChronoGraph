import Foundation
import Testing
@testable import ChronoGraph

struct CloudPasswordAuthenticationTests {
    @Test func usernameCanonicalizationMatchesServerAndRejectsUnsupportedNames() throws {
        #expect(try CloudPasswordPolicy.username("  Friend.Name_1-2\n") == "friend.name_1-2")
        for value in ["ab", String(repeating: "a", count: 33), "朋友123", "friend name", "friend@example.com", "a/b"] {
            #expect(throws: (any Error).self) { try CloudPasswordPolicy.username(value) }
        }
    }
    @Test func passwordBoundariesUseUnicodeScalarsAndPreserveWhitespace() throws {
        try CloudPasswordPolicy.validate("            ")
        try CloudPasswordPolicy.validate(String(repeating: "😀", count: 128))
        try CloudPasswordPolicy.validate(" e\u{301} password ")
        #expect(throws: (any Error).self) { try CloudPasswordPolicy.validate("           ") }
        #expect(throws: (any Error).self) { try CloudPasswordPolicy.validate(String(repeating: "a", count: 129)) }
        // Twelve displayed letters can contain twenty-four Unicode scalars.
        try CloudPasswordPolicy.validate(String(repeating: "e\u{301}", count: 6))
        #expect(CloudPasswordPolicy.matches("  preserve spaces  ", "  preserve spaces  "))
        #expect(!CloudPasswordPolicy.matches("  preserve spaces  ", "preserve spaces"))
        // Swift String equality normalizes these spellings, while the server hashes
        // the exact UTF-8 password. Confirmation must preserve that distinction.
        #expect("é" == "e\u{301}")
        #expect(!CloudPasswordPolicy.matches("é", "e\u{301}"))
    }
    @Test func passwordDeviceIdentityIsCanonicalAndSeparatedFromAppleAndOtherAccounts() throws {
        let first = try CloudDeviceIdentityPolicy.storageKey(endpoint: "https://EXAMPLE.com/chronograph/", passwordUsername: "Friend.Name")
        #expect(first == (try CloudDeviceIdentityPolicy.storageKey(endpoint: "https://example.com/chronograph", passwordUsername: "friend.name")))
        #expect(first != (try CloudDeviceIdentityPolicy.storageKey(endpoint: "https://example.com/chronograph", passwordUsername: "other.name")))
        #expect(first != (try CloudDeviceIdentityPolicy.storageKey(endpoint: "https://example.com/chronograph", appleUserID: "friend.name")))
        #expect(first != (try CloudDeviceIdentityPolicy.storageKey(endpoint: "https://example.com/another", passwordUsername: "friend.name")))
        #expect(!first.contains("friend"))
    }
    @Test func passwordSessionsRestoreWithoutAppleAndLegacySessionsKeepTheirProvider() throws {
        let legacy = Data("""
        {"access_token":"synthetic-test-only","token_type":"bearer","expires_at":"2099-01-01T00:00:00Z","user":{"id":"11111111-1111-4111-8111-111111111111","display_name":"Friend"},"device_id":"44444444-4444-4444-8444-444444444444"}
        """.utf8)
        let apple = try CloudJSON.decoder().decode(CloudSession.self, from: legacy)
        #expect(!apple.usesPassword)
        #expect(!apple.canRestore(appleSignInAvailable: false))
        #expect(apple.canRestore(appleSignInAvailable: true))
        let password = CloudSession(accessToken: apple.accessToken, tokenType: apple.tokenType, expiresAt: apple.expiresAt,
                                    user: apple.user, deviceId: apple.deviceId, authProvider: "password")
        let restored = try CloudJSON.decoder().decode(CloudSession.self, from: CloudJSON.encoder().encode(password))
        #expect(restored.usesPassword)
        #expect(restored.canRestore(appleSignInAvailable: false))
        #expect(restored.authProvider == "password")
        let unknown = CloudSession(accessToken: apple.accessToken, tokenType: apple.tokenType, expiresAt: apple.expiresAt,
                                   user: apple.user, deviceId: apple.deviceId, authProvider: "unknown")
        #expect(!unknown.canRestore(appleSignInAvailable: true))
    }
}
