import Foundation
import Testing
@testable import ChronoGraph

struct CloudBuildConfigurationTests {
    @Test func onlyTheExplicitSigningOptInEnablesAppleLogin() {
        #expect(CloudBuildConfiguration.appleSignInEnabled(value: "YES"))
        let disabledValues: [Any?] = [nil, "NO", "", "yes", "true", "1", " YES ",
                                      "$(CHRONOGRAPH_APPLE_SIGN_IN)", NSNumber(value: true)]
        for value in disabledValues {
            #expect(!CloudBuildConfiguration.appleSignInEnabled(value: value))
        }
    }
}
