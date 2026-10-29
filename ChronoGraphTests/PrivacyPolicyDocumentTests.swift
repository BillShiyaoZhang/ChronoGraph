import Foundation
import Testing
@testable import ChronoGraph

struct PrivacyPolicyDocumentTests {
    @Test func appBundleIncludesTheEnglishPolicy() throws {
        let policy = try #require(PrivacyPolicyDocument.text(languageCode: "en"))
        #expect(policy.hasPrefix("# Privacy Policy"))
        #expect(policy.contains("ChronoGraph processes calendar selection"))
        #expect(policy.contains("## Optional Cloud Collaboration"))
    }

    @Test func appBundleIncludesTheChinesePolicy() throws {
        let policy = try #require(PrivacyPolicyDocument.text(languageCode: "zh-Hans"))
        #expect(policy.hasPrefix("# 隐私政策"))
        #expect(policy.contains("ChronoGraph 在设备上处理日历筛选"))
        #expect(policy.contains("## 可选云端协作"))
    }
}
