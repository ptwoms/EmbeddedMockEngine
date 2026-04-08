import XCTest
@testable import EmbeddedMockEngine

final class MockConfigurationTests: XCTestCase {

    // MARK: - JSON decoding

    func test_decodesMinimalConfiguration() throws {
        let json = """
        {
          "routes": []
        }
        """
        let config = try decode(json)
        XCTAssertTrue(config.routes.isEmpty)
        XCTAssertNil(config.settings)
    }

    func test_decodesSettings() throws {
        let json = """
        {
          "settings": { "port": 9090, "logRequests": true, "globalDelay": 0.5 },
          "routes": []
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.settings?.port, 9090)
        XCTAssertEqual(config.settings?.logRequests, true)
        XCTAssertEqual(config.settings?.globalDelay, 0.5)
    }

    func test_decodesFullRoute() throws {
        let json = """
        {
          "routes": [{
            "id": "test-route",
            "priority": 5,
            "request": {
              "method": "POST",
              "urlPattern": "/api/users",
              "headers": { "content-type": "application/json" },
              "queryParameters": { "dryRun": "true" },
              "bodyPattern": "name"
            },
            "response": {
              "statusCode": 201,
              "headers": { "Content-Type": "application/json" },
              "body": "{\\"id\\":1}",
              "delay": 0.2
            }
          }]
        }
        """
        let config = try decode(json)
        let route  = try XCTUnwrap(config.routes.first)

        XCTAssertEqual(route.id,       "test-route")
        XCTAssertEqual(route.priority, 5)

        let req = route.request
        XCTAssertEqual(req.method,              .post)
        XCTAssertEqual(req.urlPattern,           "/api/users")
        XCTAssertEqual(req.headers?["content-type"], "application/json")
        XCTAssertEqual(req.queryParameters?["dryRun"], "true")
        XCTAssertEqual(req.bodyPattern,          "name")

        let resp = route.response
        XCTAssertEqual(resp.statusCode,          201)
        XCTAssertEqual(resp.headers?["Content-Type"], "application/json")
        XCTAssertEqual(resp.body,                "{\"id\":1}")
        XCTAssertEqual(resp.delay,               0.2)
    }

    func test_decodesBodyFile() throws {
        let json = """
        {
          "routes": [{
            "id": "file-route",
            "request": { "method": "GET", "urlPattern": "/data" },
            "response": { "statusCode": 200, "bodyFile": "responses/data.json" }
          }]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.routes.first?.response.bodyFile, "responses/data.json")
    }

    func test_decodesAllHttpMethods() throws {
        let methods: [String: HTTPMethod] = [
            "GET":     .get,
            "POST":    .post,
            "PUT":     .put,
            "DELETE":  .delete,
            "PATCH":   .patch,
            "HEAD":    .head,
            "OPTIONS": .options,
            "TRACE":   .trace,
            "CONNECT": .connect,
        ]

        for (raw, expected) in methods {
            let json = """
            {
              "routes": [{
                "id": "r",
                "request": { "method": "\(raw)" },
                "response": { "statusCode": 200 }
              }]
            }
            """
            let config = try decode(json)
            XCTAssertEqual(config.routes.first?.request.method, expected,
                           "Failed for method: \(raw)")
        }
    }

    func test_decoding_failsForInvalidJSON() {
        let json = "{ invalid json }"
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: - Roundtrip encode → decode

    func test_encodeDecodesRoundtrip() throws {
        let original = MockConfiguration(
            settings: MockServerSettings(port: 8080, globalDelay: 0.1, logRequests: true),
            routes: [
                MockRoute(
                    id: "rt",
                    request: MockRequestMatcher(method: .get, urlPattern: "/ping"),
                    response: MockResponseDefinition(statusCode: 200, body: "pong")
                )
            ]
        )

        let data   = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MockConfiguration.self, from: data)

        XCTAssertEqual(decoded.settings?.port, 8080)
        XCTAssertEqual(decoded.routes.first?.id, "rt")
        XCTAssertEqual(decoded.routes.first?.response.body, "pong")
    }

    // MARK: - MockServerSettings defaults

    func test_serverSettings_defaultsAreNil() {
        let settings = MockServerSettings()
        XCTAssertNil(settings.port)
        XCTAssertNil(settings.globalDelay)
        XCTAssertNil(settings.logRequests)
    }

    // MARK: - Private helpers

    private func decode(_ json: String) throws -> MockConfiguration {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(MockConfiguration.self, from: data)
    }
}
