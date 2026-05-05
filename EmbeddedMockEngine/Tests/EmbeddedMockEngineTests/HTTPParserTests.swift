import XCTest
@testable import EmbeddedMockEngine

final class HTTPParserTests: XCTestCase {

    // MARK: - isComplete

    func test_isComplete_returnsFalse_whenEmpty() {
        XCTAssertFalse(HTTPParser.isComplete(Data()))
    }

    func test_isComplete_returnsFalse_whenHeadersIncomplete() {
        let partial = "GET /path HTTP/1.1\r\nHost: localhost"
        XCTAssertFalse(HTTPParser.isComplete(partial.data(using: .utf8)!))
    }

    func test_isComplete_returnsTrue_forRequestWithNoBody() {
        let raw = "GET /api/users HTTP/1.1\r\nHost: localhost\r\n\r\n"
        XCTAssertTrue(HTTPParser.isComplete(raw.data(using: .utf8)!))
    }

    func test_isComplete_returnsTrue_whenBodyFullyReceived() {
        let raw  = "POST /echo HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
        XCTAssertTrue(HTTPParser.isComplete(raw.data(using: .utf8)!))
    }

    func test_isComplete_returnsFalse_whenBodyPartiallyReceived() {
        let raw = "POST /echo HTTP/1.1\r\nContent-Length: 10\r\n\r\nhello"
        XCTAssertFalse(HTTPParser.isComplete(raw.data(using: .utf8)!))
    }

    // MARK: - parse – request line

    func test_parse_returnsNil_forEmptyData() {
        XCTAssertNil(HTTPParser.parse(data: Data()))
    }

    func test_parse_extractsMethod() {
        let raw = "DELETE /resource HTTP/1.1\r\n\r\n"
        let req = HTTPParser.parse(data: raw.data(using: .utf8)!)!
        XCTAssertEqual(req.method, "DELETE")
    }

    func test_parse_extractsPath_withoutQuery() {
        let raw = "GET /api/users HTTP/1.1\r\n\r\n"
        let req = HTTPParser.parse(data: raw.data(using: .utf8)!)!
        XCTAssertEqual(req.path, "/api/users")
        XCTAssertTrue(req.queryParameters.isEmpty)
    }

    func test_parse_extractsPath_andQueryParameters() {
        let raw = "GET /api/users?page=2&limit=10 HTTP/1.1\r\n\r\n"
        let req = HTTPParser.parse(data: raw.data(using: .utf8)!)!
        XCTAssertEqual(req.path, "/api/users")
        XCTAssertEqual(req.queryParameters["page"],  "2")
        XCTAssertEqual(req.queryParameters["limit"], "10")
    }

    func test_parse_decodesPercentEncodedPath() {
        let raw = "GET /api/hello%20world HTTP/1.1\r\n\r\n"
        let req = HTTPParser.parse(data: raw.data(using: .utf8)!)!
        XCTAssertEqual(req.path, "/api/hello world")
    }

    func test_parse_decodesPlusSignInQuery() {
        let raw = "GET /search?q=hello+world HTTP/1.1\r\n\r\n"
        let req = HTTPParser.parse(data: raw.data(using: .utf8)!)!
        XCTAssertEqual(req.queryParameters["q"], "hello world")
    }

    // MARK: - parse – headers

    func test_parse_lowercasesHeaderNames() {
        let raw = "GET / HTTP/1.1\r\nContent-Type: application/json\r\nX-Custom-Header: val\r\n\r\n"
        let req = HTTPParser.parse(data: raw.data(using: .utf8)!)!
        XCTAssertEqual(req.headers["content-type"],    "application/json")
        XCTAssertEqual(req.headers["x-custom-header"], "val")
    }

    func test_parse_extractsHostHeader() {
        let raw = "GET / HTTP/1.1\r\nHost: localhost:8080\r\n\r\n"
        let req = HTTPParser.parse(data: raw.data(using: .utf8)!)!
        XCTAssertEqual(req.headers["host"], "localhost:8080")
    }

    // MARK: - parse – body

    func test_parse_extractsBody() {
        let bodyString = #"{"name":"Alice"}"#
        let raw = "POST /users HTTP/1.1\r\nContent-Length: \(bodyString.utf8.count)\r\n\r\n\(bodyString)"
        let req = HTTPParser.parse(data: raw.data(using: .utf8)!)!
        XCTAssertNotNil(req.body)
        let bodyText = String(data: req.body!, encoding: .utf8)
        XCTAssertEqual(bodyText, bodyString)
    }

    func test_parse_nilBody_forGetRequest() {
        let raw = "GET /users HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let req = HTTPParser.parse(data: raw.data(using: .utf8)!)!
        XCTAssertNil(req.body)
    }

    // MARK: - parseURL helpers

    func test_parseURL_noQuery() {
        let (path, params) = HTTPParser.parseURL("/api/v1/resource")
        XCTAssertEqual(path, "/api/v1/resource")
        XCTAssertTrue(params.isEmpty)
    }

    func test_parseURL_withMultipleParams() {
        let (path, params) = HTTPParser.parseURL("/search?a=1&b=two&c=three")
        XCTAssertEqual(path, "/search")
        XCTAssertEqual(params["a"], "1")
        XCTAssertEqual(params["b"], "two")
        XCTAssertEqual(params["c"], "three")
    }

    func test_parseQueryString_emptyValue() {
        let params = HTTPParser.parseQueryString("key=&other=value")
        XCTAssertEqual(params["key"],   "")
        XCTAssertEqual(params["other"], "value")
    }
}
