import XCTest
@testable import EmbeddedMockEngine
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// End-to-end integration tests that start a real `MockEngine` on localhost
/// and exercise it with `URLSession` HTTP requests.
final class MockServerIntegrationTests: XCTestCase {

    private var engine: MockEngine!
    private var baseURL: URL!

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

    private func startEngine(routes: [MockRoute] = []) async throws {
        for route in routes { await engine.addRoute(route) }
        let port = try await engine.start()
        baseURL = URL(string: "http://localhost:\(port)")!
    }

    private func get(_ path: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return try await fetch(request)
    }

    private func post(_ path: String, body: Data?, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody   = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return try await fetch(request)
    }

    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config  = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        return (data, httpResponse)
    }

    // MARK: - Lifecycle tests

    func test_start_returnsNonZeroPort() async throws {
        let port = try await engine.start()
        XCTAssertGreaterThan(port, 0)
        await engine.stop()
    }

    func test_start_twice_throws() async throws {
        try await engine.start()
        do {
            try await engine.start()
            XCTFail("Expected error on second start")
        } catch MockEngineError.alreadyRunning {
            // Expected
        }
    }

    func test_stop_clearsPort() async throws {
        try await engine.start()
        await engine.stop()
        let port = await engine.currentPort
        XCTAssertNil(port)
    }

    // MARK: - Inline response

    func test_inlineBody_returnedCorrectly() async throws {
        let route = MockRoute(
            id: "ping",
            request: MockRequestMatcher(method: .get, urlPattern: "/ping"),
            response: MockResponseDefinition(statusCode: 200, body: "pong")
        )
        try await startEngine(routes: [route])

        let (data, response) = try await get("/ping")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "pong")
    }

    // MARK: - 404 fallback

    func test_noMatchingRoute_returns404() async throws {
        try await startEngine()
        let (_, response) = try await get("/nonexistent")
        XCTAssertEqual(response.statusCode, 404)
    }

    // MARK: - Method matching

    func test_methodMismatch_returns404() async throws {
        let route = MockRoute(
            id: "only-post",
            request: MockRequestMatcher(method: .post, urlPattern: "/data"),
            response: MockResponseDefinition(statusCode: 200, body: "ok")
        )
        try await startEngine(routes: [route])

        let (_, response) = try await get("/data")
        XCTAssertEqual(response.statusCode, 404)
    }

    // MARK: - Query parameter matching

    func test_queryParamMatch_returnsCorrectRoute() async throws {
        let routeWithParam = MockRoute(
            id: "page-1",
            request: MockRequestMatcher(
                method: .get,
                urlPattern: "/items",
                queryParameters: ["page": "1"]
            ),
            response: MockResponseDefinition(statusCode: 200, body: "page1")
        )
        let routeDefault = MockRoute(
            id: "page-other",
            request: MockRequestMatcher(method: .get, urlPattern: "/items"),
            response: MockResponseDefinition(statusCode: 200, body: "other")
        )
        try await startEngine(routes: [routeWithParam, routeDefault])

        // page=1 should match first route
        var components = URLComponents(url: baseURL.appendingPathComponent("/items"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "page", value: "1")]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        let (data1, _) = try await fetch(req)
        XCTAssertEqual(String(data: data1, encoding: .utf8), "page1")

        // page=2 should fall through to default route
        components.queryItems = [URLQueryItem(name: "page", value: "2")]
        req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        let (data2, _) = try await fetch(req)
        XCTAssertEqual(String(data: data2, encoding: .utf8), "other")
    }

    // MARK: - Header matching

    func test_headerMatch_requiredHeaderPresent() async throws {
        let route = MockRoute(
            id: "json-only",
            request: MockRequestMatcher(
                method: .get,
                urlPattern: "/data",
                headers: ["accept": "application/json"]
            ),
            response: MockResponseDefinition(statusCode: 200, body: #"{"ok":true}"#)
        )
        try await startEngine(routes: [route])

        let (data, response) = try await get("/data", headers: ["accept": "application/json"])
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNotNil(String(data: data, encoding: .utf8))
    }

    // MARK: - POST with body

    func test_postRoute_returnsCreated() async throws {
        let route = MockRoute(
            id: "create",
            request: MockRequestMatcher(method: .post, urlPattern: "/users"),
            response: MockResponseDefinition(statusCode: 201, body: #"{"id":1}"#)
        )
        try await startEngine(routes: [route])

        let body = #"{"name":"Alice"}"#.data(using: .utf8)!
        let (data, response) = try await post(
            "/users",
            body: body,
            headers: ["Content-Type": "application/json"]
        )
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertNotNil(String(data: data, encoding: .utf8))
    }

    // MARK: - Wildcard URL matching

    func test_wildcardPath_matches() async throws {
        let route = MockRoute(
            id: "wildcard",
            request: MockRequestMatcher(method: .get, urlPattern: "/files/**"),
            response: MockResponseDefinition(statusCode: 200, body: "found")
        )
        try await startEngine(routes: [route])

        let (_, resp1) = try await get("/files/images/logo.png")
        XCTAssertEqual(resp1.statusCode, 200)

        let (_, resp2) = try await get("/files/docs/guide.pdf")
        XCTAssertEqual(resp2.statusCode, 200)
    }

    // MARK: - Priority routing

    func test_highPriorityRoute_winsOverLowerPriority() async throws {
        let lowPriority = MockRoute(
            id: "low",
            request: MockRequestMatcher(method: .get, urlPattern: "/api/*"),
            response: MockResponseDefinition(statusCode: 200, body: "low"),
            priority: 0
        )
        let highPriority = MockRoute(
            id: "high",
            request: MockRequestMatcher(method: .get, urlPattern: "/api/special"),
            response: MockResponseDefinition(statusCode: 200, body: "high"),
            priority: 10
        )
        try await startEngine(routes: [lowPriority, highPriority])

        let (data, _) = try await get("/api/special")
        XCTAssertEqual(String(data: data, encoding: .utf8), "high")
    }

    // MARK: - Response headers

    func test_customResponseHeaders_returned() async throws {
        let route = MockRoute(
            id: "headers",
            request: MockRequestMatcher(method: .get, urlPattern: "/info"),
            response: MockResponseDefinition(
                statusCode: 200,
                headers: ["X-Custom": "test-value", "Content-Type": "application/json"],
                body: "{}"
            )
        )
        try await startEngine(routes: [route])

        let (_, response) = try await get("/info")
        XCTAssertEqual(response.value(forHTTPHeaderField: "X-Custom"), "test-value")
    }

    // MARK: - Stop and restart

    func test_stopAndRestart_serverHandlesRequestsAfterRestart() async throws {
        let route = MockRoute(
            id: "ping",
            request: MockRequestMatcher(method: .get, urlPattern: "/ping"),
            response: MockResponseDefinition(statusCode: 200, body: "pong")
        )
        try await startEngine(routes: [route])

        // First request succeeds.
        let (data1, resp1) = try await get("/ping")
        XCTAssertEqual(resp1.statusCode, 200)
        XCTAssertEqual(String(data: data1, encoding: .utf8), "pong")

        // Stop and then restart on a different (OS-assigned) port.
        await engine.stop()
        let newPort = try await engine.start()
        baseURL = URL(string: "http://localhost:\(newPort)")!

        // Request on the new port should succeed.
        let (data2, resp2) = try await get("/ping")
        XCTAssertEqual(resp2.statusCode, 200)
        XCTAssertEqual(String(data: data2, encoding: .utf8), "pong")
    }

    // MARK: - Large multipart/form-data upload

    /// Sends a synthetic multipart body that is ~4 MB in size and verifies the
    /// server reads the full payload and returns the configured response.
    func test_largeMultipartUpload_handledCorrectly() async throws {
        let route = MockRoute(
            id: "upload",
            request: MockRequestMatcher(method: .post, urlPattern: "/upload"),
            response: MockResponseDefinition(statusCode: 200, body: #"{"status":"ok"}"#)
        )
        try await startEngine(routes: [route])

        let boundary = "----MockBoundary1234567890"
        let fieldHeader = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"large.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        let fieldFooter = "\r\n--\(boundary)--\r\n"

        // Build a 4 MB binary payload.
        let payloadSize = 4 * 1024 * 1024
        var bodyData = Data()
        bodyData.append(contentsOf: fieldHeader.utf8)
        bodyData.append(Data(repeating: 0xAB, count: payloadSize))
        bodyData.append(contentsOf: fieldFooter.utf8)

        var request = URLRequest(url: baseURL.appendingPathComponent("/upload"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await fetch(request)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"status":"ok"}"#)
    }

    func test_configuredViaFile_servesResponses() async throws {
        guard let configURL = Bundle.module.url(forResource: "mock_config", withExtension: "json") else {
            XCTFail("mock_config.json not found in test bundle")
            return
        }
        try await engine.loadConfiguration(from: configURL)
        let port = try await engine.start()
        baseURL = URL(string: "http://localhost:\(port)")!

        // GET /api/users should return the users.json content
        let (data, response) = try await get("/api/users")
        XCTAssertEqual(response.statusCode, 200)

        let json = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        XCTAssertNotNil(json["users"])
    }
}

// MARK: - AnyCodable helper (lightweight JSON any-value wrapper for assertions)

private struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Int.self)    { value = v; return }
        if let v = try? container.decode(Double.self)  { value = v; return }
        if let v = try? container.decode(Bool.self)    { value = v; return }
        if let v = try? container.decode(String.self)  { value = v; return }
        if let v = try? container.decode([AnyCodable].self) { value = v.map(\.value); return }
        let dict = try container.decode([String: AnyCodable].self)
        value = dict.mapValues(\.value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Int:    try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool:   try container.encode(v)
        case let v as String: try container.encode(v)
        default: try container.encodeNil()
        }
    }
}
