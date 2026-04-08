import XCTest
@testable import EmbeddedMockEngine

final class RequestMatcherTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(
        method: String = "GET",
        path: String = "/",
        queryParameters: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> HTTPRequest {
        HTTPRequest(
            method: method,
            path: path,
            queryParameters: queryParameters,
            headers: headers,
            body: body,
            rawURL: path
        )
    }

    private func makeMatcher(
        method: HTTPMethod? = nil,
        urlPattern: String? = nil,
        headers: [String: String]? = nil,
        queryParameters: [String: String]? = nil,
        bodyPattern: String? = nil
    ) -> MockRequestMatcher {
        MockRequestMatcher(
            method: method,
            urlPattern: urlPattern,
            headers: headers,
            queryParameters: queryParameters,
            bodyPattern: bodyPattern
        )
    }

    // MARK: - Method matching

    func test_method_nil_matchesAnyMethod() {
        let req = makeRequest(method: "DELETE")
        let matcher = makeMatcher(method: nil)
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_method_matchesCaseInsensitively() {
        let req     = makeRequest(method: "get")
        let matcher = makeMatcher(method: .get)
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_method_doesNotMatch_wrongMethod() {
        let req     = makeRequest(method: "POST")
        let matcher = makeMatcher(method: .get)
        XCTAssertFalse(RequestMatcher.matches(request: req, against: matcher))
    }

    // MARK: - URL pattern matching (exact)

    func test_urlPattern_exactMatch() {
        let req     = makeRequest(path: "/api/users")
        let matcher = makeMatcher(urlPattern: "/api/users")
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_urlPattern_exactMatch_fails_differentPath() {
        let req     = makeRequest(path: "/api/orders")
        let matcher = makeMatcher(urlPattern: "/api/users")
        XCTAssertFalse(RequestMatcher.matches(request: req, against: matcher))
    }

    // MARK: - URL pattern matching (wildcard *)

    func test_urlPattern_singleWildcard_matchesSegment() {
        let req     = makeRequest(path: "/api/users/42")
        let matcher = makeMatcher(urlPattern: "/api/users/*")
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_urlPattern_singleWildcard_doesNotMatch_multipleSegments() {
        let req     = makeRequest(path: "/api/users/42/posts")
        let matcher = makeMatcher(urlPattern: "/api/users/*")
        XCTAssertFalse(RequestMatcher.matches(request: req, against: matcher))
    }

    // MARK: - URL pattern matching (double wildcard **)

    func test_urlPattern_doubleWildcard_matchesMultipleSegments() {
        let req     = makeRequest(path: "/api/users/42/posts/7")
        let matcher = makeMatcher(urlPattern: "/api/**")
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_urlPattern_doubleWildcard_matchesEmptyTrailing() {
        let req     = makeRequest(path: "/api/")
        let matcher = makeMatcher(urlPattern: "/api/**")
        // "/api/" has a trailing slash but "**" matches ""
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    // MARK: - URL pattern matching (path parameter)

    func test_urlPattern_pathParameter_matchesSegment() {
        let req     = makeRequest(path: "/api/users/99")
        let matcher = makeMatcher(urlPattern: "/api/users/{id}")
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    // MARK: - URL pattern matching (explicit regex)

    func test_urlPattern_explicitRegex_matches() {
        let req     = makeRequest(path: "/api/users/123")
        let matcher = makeMatcher(urlPattern: "~/api/users/[0-9]+~")
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_urlPattern_explicitRegex_doesNotMatch() {
        let req     = makeRequest(path: "/api/users/abc")
        let matcher = makeMatcher(urlPattern: "~/api/users/[0-9]+~")
        XCTAssertFalse(RequestMatcher.matches(request: req, against: matcher))
    }

    // MARK: - Header matching (subset)

    func test_headers_subset_matches() {
        let req = makeRequest(headers: [
            "content-type":  "application/json",
            "authorization": "Bearer token",
            "accept":        "application/json"
        ])
        let matcher = makeMatcher(headers: ["content-type": "application/json"])
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_headers_missing_header_doesNotMatch() {
        let req     = makeRequest(headers: ["accept": "application/json"])
        let matcher = makeMatcher(headers: ["authorization": "Bearer token"])
        XCTAssertFalse(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_headers_wrong_value_doesNotMatch() {
        let req     = makeRequest(headers: ["content-type": "text/html"])
        let matcher = makeMatcher(headers: ["content-type": "application/json"])
        XCTAssertFalse(RequestMatcher.matches(request: req, against: matcher))
    }

    // MARK: - Query parameter matching (subset)

    func test_queryParams_subset_matches() {
        let req = makeRequest(queryParameters: ["page": "1", "limit": "20", "sort": "asc"])
        let matcher = makeMatcher(queryParameters: ["page": "1"])
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_queryParams_missing_param_doesNotMatch() {
        let req     = makeRequest(queryParameters: ["limit": "20"])
        let matcher = makeMatcher(queryParameters: ["page": "1"])
        XCTAssertFalse(RequestMatcher.matches(request: req, against: matcher))
    }

    // MARK: - Body pattern matching

    func test_bodyPattern_matches() {
        let body    = #"{"name":"Alice"}"#.data(using: .utf8)
        let req     = makeRequest(method: "POST", path: "/users", body: body)
        let matcher = makeMatcher(bodyPattern: #""name"\s*:\s*"Alice""#)
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_bodyPattern_doesNotMatch() {
        let body    = #"{"name":"Bob"}"#.data(using: .utf8)
        let req     = makeRequest(method: "POST", path: "/users", body: body)
        let matcher = makeMatcher(bodyPattern: #""name"\s*:\s*"Alice""#)
        XCTAssertFalse(RequestMatcher.matches(request: req, against: matcher))
    }

    func test_bodyPattern_failsWhenNoBody() {
        let req     = makeRequest(method: "POST", path: "/users", body: nil)
        let matcher = makeMatcher(bodyPattern: ".*")
        XCTAssertFalse(RequestMatcher.matches(request: req, against: matcher))
    }

    // MARK: - Combined criteria

    func test_combined_allCriteria_match() {
        let body = #"{"action":"create"}"#.data(using: .utf8)
        let req  = makeRequest(
            method: "POST",
            path: "/api/tasks",
            queryParameters: ["dryRun": "false"],
            headers: ["content-type": "application/json"],
            body: body
        )
        let matcher = makeMatcher(
            method: .post,
            urlPattern: "/api/tasks",
            headers: ["content-type": "application/json"],
            queryParameters: ["dryRun": "false"],
            bodyPattern: #""action"\s*:\s*"create""#
        )
        XCTAssertTrue(RequestMatcher.matches(request: req, against: matcher))
    }

    // MARK: - URLPatternMatcher unit tests

    func test_globToRegex_exactPath() {
        let regex = URLPatternMatcher.globToRegex("/api/users")
        // Regex should match exact path
        XCTAssertTrue(URLPatternMatcher.matches(path: "/api/users", pattern: "/api/users"))
        XCTAssertFalse(URLPatternMatcher.matches(path: "/api/other", pattern: "/api/users"))
        // Pattern should be anchored (starts with ^ ends with $)
        XCTAssertTrue(regex.hasPrefix("^"))
        XCTAssertTrue(regex.hasSuffix("$"))
    }

    func test_globToRegex_singleWildcard() {
        let regex = URLPatternMatcher.globToRegex("/api/users/*")
        XCTAssertTrue(regex.contains("[^/]+"))
    }

    func test_globToRegex_doubleWildcard() {
        let regex = URLPatternMatcher.globToRegex("/api/**")
        XCTAssertTrue(regex.contains(".*"))
    }

    func test_globToRegex_pathParam() {
        let regex = URLPatternMatcher.globToRegex("/api/{id}")
        XCTAssertTrue(regex.contains("[^/]+"))
    }
}
