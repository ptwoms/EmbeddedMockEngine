#if canImport(Security)
import XCTest
@testable import EmbeddedMockEngine
import Foundation

/// Integration tests that start a real `MockEngine` over HTTPS (TLS 1.2+) and
/// exercise it with `URLSession` requests that trust the bundled self-signed cert.
///
/// These tests run only on Darwin (macOS / iOS), where SecureTransport is available.
final class MockServerTLSTests: XCTestCase {

    private var engine: MockEngine!
    private var baseURL: URL!

    // MARK: - Certificate resources

    private var certURL: URL {
        guard let url = Bundle.module.url(forResource: "tls_cert", withExtension: "pem") else {
            fatalError("tls_cert.pem not found in test bundle")
        }
        return url
    }

    private var keyURL: URL {
        guard let url = Bundle.module.url(forResource: "tls_key", withExtension: "pem") else {
            fatalError("tls_key.pem not found in test bundle")
        }
        return url
    }

    // MARK: - Setup / teardown

    override func setUp() async throws {
        try await super.setUp()
        engine = MockEngine()
    }

    override func tearDown() async throws {
        await engine?.stop()
        engine = nil
        baseURL = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func startEngineWithTLS(routes: [MockRoute] = []) async throws {
        for route in routes { await engine.addRoute(route) }
        let tls = TLSConfiguration(certificateFile: certURL, privateKeyFile: keyURL)
        let port = try await engine.start(tls: tls)
        baseURL = URL(string: "https://localhost:\(port)")!
    }

    /// Returns a `URLSession` configured to trust the self-signed server certificate.
    private func makeTrustingSession(certURL: URL) -> URLSession {
        let delegate = SelfSignedCertDelegate(certURL: certURL)
        return URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = makeTrustingSession(certURL: certURL)
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (data, http)
    }

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        return try await fetch(req)
    }

    // MARK: - Tests

    func test_httpsServer_starts_returnsNonZeroPort() async throws {
        let tls = TLSConfiguration(certificateFile: certURL, privateKeyFile: keyURL)
        let port = try await engine.start(tls: tls)
        XCTAssertGreaterThan(port, 0)
    }

    func test_httpsServer_respondsToGetRequest() async throws {
        let route = MockRoute(
            id: "ping",
            request: MockRequestMatcher(method: .get, urlPattern: "/ping"),
            response: MockResponseDefinition(statusCode: 200, body: "pong")
        )
        try await startEngineWithTLS(routes: [route])

        let (data, response) = try await get("/ping")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "pong")
    }

    func test_httpsServer_404_forUnmatchedRoute() async throws {
        try await startEngineWithTLS()
        let (_, response) = try await get("/nope")
        XCTAssertEqual(response.statusCode, 404)
    }

    func test_httpsServer_customHeaders_returned() async throws {
        let route = MockRoute(
            id: "headers",
            request: MockRequestMatcher(method: .get, urlPattern: "/info"),
            response: MockResponseDefinition(
                statusCode: 200,
                headers: ["X-TLS": "enabled"],
                body: "{}"
            )
        )
        try await startEngineWithTLS(routes: [route])
        let (_, response) = try await get("/info")
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-TLS"), "enabled")
    }

    func test_tlsConfiguration_viaSettings() async throws {
        let tls = TLSConfiguration(certificateFile: certURL, privateKeyFile: keyURL)
        let settings = MockServerSettings(tlsConfiguration: tls)
        await engine.configure(with: MockConfiguration(settings: settings, routes: []))
        let route = MockRoute(
            id: "ping",
            request: MockRequestMatcher(method: .get, urlPattern: "/ping"),
            response: MockResponseDefinition(statusCode: 200, body: "pong")
        )
        await engine.addRoute(route)
        let port = try await engine.start()
        let url = URL(string: "https://localhost:\(port)")!

        var req = URLRequest(url: url.appendingPathComponent("/ping"))
        req.httpMethod = "GET"
        let (data, response) = try await fetch(req)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "pong")
    }

    func test_plainStart_stillWorksAfterTLSStart() async throws {
        // Start with TLS, stop, then restart plain – must not error.
        let tls = TLSConfiguration(certificateFile: certURL, privateKeyFile: keyURL)
        let tlsPort = try await engine.start(tls: tls)
        XCTAssertGreaterThan(tlsPort, 0)
        await engine.stop()

        let plainPort = try await engine.start()
        XCTAssertGreaterThan(plainPort, 0)
    }
}

// MARK: - SelfSignedCertDelegate

/// A `URLSessionDelegate` that accepts the bundled self-signed test certificate
/// and rejects all other untrusted certificates.
private final class SelfSignedCertDelegate: NSObject, URLSessionDelegate {

    private let certURL: URL

    init(certURL: URL) {
        self.certURL = certURL
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Load the expected certificate from the bundle.
        guard
            let certData = try? Data(contentsOf: certURL),
            let certPEM  = String(data: certData, encoding: .utf8),
            let derData  = derFromPEM(certPEM, label: "CERTIFICATE"),
            let expected = SecCertificateCreateWithData(nil, derData as CFData)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Verify the server presents exactly our expected self-signed cert.
        let serverCerts: [SecCertificate] = {
            (0..<SecTrustGetCertificateCount(serverTrust)).compactMap {
                SecTrustGetCertificateAtIndex(serverTrust, $0)
            }
        }()

        let expectedBytes = SecCertificateGetData(expected) as Data
        let trusted = serverCerts.contains {
            (SecCertificateGetData($0) as Data) == expectedBytes
        }

        if trusted {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - PEM helper (test-local copy)

private func derFromPEM(_ pem: String, label: String) -> Data? {
    let begin = "-----BEGIN \(label)-----"
    let end   = "-----END \(label)-----"
    guard
        let startRange = pem.range(of: begin),
        let endRange   = pem.range(of: end)
    else { return nil }
    let b64 = String(pem[startRange.upperBound..<endRange.lowerBound])
        .components(separatedBy: .whitespacesAndNewlines)
        .joined()
    return Data(base64Encoded: b64)
}

#endif // canImport(Security)
