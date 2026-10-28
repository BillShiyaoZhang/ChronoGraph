import Foundation
import XCTest
@testable import ChronoGraph

#if targetEnvironment(simulator)
/// Explicitly opted-in HTTPS probes send no credentials and perform GET requests only.
@MainActor
final class CloudLiveReadOnlyIntegrationTests: XCTestCase {
    private static let configuredEndpoint = "https://agent-communication.online/chronograph/"
    private var endpoint: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["CHRONOGRAPH_LIVE_ENDPOINT"] == Self.configuredEndpoint else {
            throw XCTSkip("Live read-only probes require the exact configured HTTPS endpoint opt-in.")
        }
        guard !ProcessInfo.processInfo.arguments.contains("-cloud-signed-in-fixtures") else {
            throw XCTSkip("Live probes must use native HTTPS rather than the UI fixture transport.")
        }
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "ChronoGraphAPIBaseURL") as? String,
                       Self.configuredEndpoint)
        endpoint = try CloudEndpointPolicy.validated(Self.configuredEndpoint)
    }

    func testNativeHTTPSReadinessIncludesTheDatabase() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: RejectReadinessRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let url = endpoint.appendingPathComponent("health/ready")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.url, url)
        XCTAssertEqual(http.url?.scheme, "https")
        XCTAssertEqual(http.statusCode, 200)
        struct Readiness: Decodable { let status: String }
        XCTAssertEqual(try JSONDecoder().decode(Readiness.self, from: data).status, "ok")
        // Proxies may combine duplicate Cache-Control fields into one comma-separated value.
        let directives = http.value(forHTTPHeaderField: "Cache-Control")?.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
        XCTAssertEqual(Set(directives), ["no-store"])
    }

    func testLiveAccountEndpointRequiresASession() async throws {
        await assertUnauthorizedGET("me")
    }

    func testLiveCalendarSourcesRequireASession() async throws {
        await assertUnauthorizedGET("sources")
    }

    private func assertUnauthorizedGET(_ path: String, file: StaticString = #filePath, line: UInt = #line) async {
        // A new client has no access token; authenticated:false exercises the server's gate.
        let client = CloudAPIClient(baseURL: endpoint)
        do {
            _ = try await client.send("GET", path, authenticated: false)
            XCTFail("An unauthenticated live GET must be rejected by the server.", file: file, line: line)
        } catch CloudClientError.http(let status, _) {
            XCTAssertEqual(status, 401, file: file, line: line)
        } catch {
            XCTFail("Live HTTPS GET failed before the expected authentication response: \(error)", file: file, line: line)
        }
    }
}

private final class RejectReadinessRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
