import Foundation

// MARK: - RequestMatcher

/// Matches an incoming ``HTTPRequest`` against a ``MockRequestMatcher`` to decide
/// whether a route should handle the request.
///
/// Matching rules
/// ==============
/// - **method**          : exact, case-insensitive.
/// - **urlPattern**      : see ``URLPatternMatcher``.
/// - **headers**         : subset match – all listed header `name: value` pairs must
///                         appear in the request (case-insensitive names, exact values).
/// - **queryParameters** : subset match – all listed params must appear in the request.
/// - **bodyPattern**     : the request body must match the regex. For `multipart/form-data`,
///                         text parts are extracted and matched individually. For
///                         `application/x-www-form-urlencoded`, decoded `key=value` pairs are
///                         matched. For other content types, the raw UTF-8 body is matched.
public struct RequestMatcher: Sendable {

    /// Returns `true` when `request` satisfies every non-nil criterion in `matcher`.
    public static func matches(request: HTTPRequest, against matcher: MockRequestMatcher) -> Bool {
        if let method = matcher.method,
           method.rawValue.uppercased() != request.method.uppercased() {
            return false
        }

        if let urlPattern = matcher.urlPattern,
           !URLPatternMatcher.matches(path: request.path, pattern: urlPattern) {
            return false
        }

        if let requiredHeaders = matcher.headers {
            for (name, value) in requiredHeaders {
                guard request.headers[name.lowercased()] == value else { return false }
            }
        }

        if let requiredParams = matcher.queryParameters {
            for (key, value) in requiredParams {
                guard request.queryParameters[key] == value else { return false }
            }
        }

        if let bodyPattern = matcher.bodyPattern {
            guard let bodyData = request.body else { return false }
            let textParts = extractMatchableText(from: bodyData, contentType: request.headers["content-type"])
            guard !textParts.isEmpty else { return false }
            guard regexMatchesAny(pattern: bodyPattern, candidates: textParts) else { return false }
        }

        return true
    }

    // MARK: - Body text extraction

    /// Extracts matchable text strings from a request body based on its Content-Type.
    ///
    /// - `multipart/form-data`: parses each part; returns text content of non-binary parts.
    /// - `application/x-www-form-urlencoded`: decodes into `key=value` pairs joined by `&`.
    /// - Everything else: attempts UTF-8 decoding of the raw body.
    private static func extractMatchableText(from body: Data, contentType: String?) -> [String] {
        guard let contentType = contentType else {
            // No Content-Type — try raw UTF-8
            if let text = String(data: body, encoding: .utf8) { return [text] }
            return []
        }

        let lowerContentType = contentType.lowercased()

        if lowerContentType.contains("multipart/form-data") {
            // Pass original contentType to preserve case-sensitive boundary value
            return extractMultipartText(from: body, contentType: contentType)
        }

        if lowerContentType.contains("application/x-www-form-urlencoded") {
            if let text = String(data: body, encoding: .utf8) {
                let decoded = text.removingPercentEncoding ?? text
                return [decoded]
            }
            return []
        }

        // Default: raw UTF-8
        if let text = String(data: body, encoding: .utf8) { return [text] }
        return []
    }

    /// Parses multipart/form-data body and returns the text content of each non-binary part.
    private static func extractMultipartText(from body: Data, contentType: String) -> [String] {
        guard let boundary = extractBoundary(from: contentType) else { return [] }

        let boundaryData = Data(("--" + boundary).utf8)
        let parts = splitMultipartBody(body, boundary: boundaryData)

        var texts: [String] = []
        for part in parts {
            // Each part has headers separated from content by \r\n\r\n
            let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let sepRange = part.range(of: separator) else { continue }

            let headerData = part[part.startIndex..<sepRange.lowerBound]
            let contentData = part[sepRange.upperBound...]

            // Check part headers for binary content
            if let headerText = String(data: headerData, encoding: .utf8) {
                let lowerHeaders = headerText.lowercased()
                // Skip parts with binary content types (images, octet-stream, etc.)
                if lowerHeaders.contains("content-type:") &&
                   !lowerHeaders.contains("text/") &&
                   !lowerHeaders.contains("application/json") {
                    continue
                }
            }

            // Try to decode part content as UTF-8 text
            if let text = String(data: contentData, encoding: .utf8) {
                // Strip trailing \r\n
                let trimmed = text.hasSuffix("\r\n") ? String(text.dropLast(2)) : text
                if !trimmed.isEmpty {
                    texts.append(trimmed)
                }
            }
        }

        return texts
    }

    /// Extracts the boundary string from a `multipart/form-data; boundary=...` Content-Type.
    private static func extractBoundary(from contentType: String) -> String? {
        for param in contentType.components(separatedBy: ";") {
            let trimmed = param.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var value = String(trimmed.dropFirst("boundary=".count))
                // Remove surrounding quotes if present
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                return value
            }
        }
        return nil
    }

    /// Splits a multipart body into individual parts using the boundary marker.
    private static func splitMultipartBody(_ body: Data, boundary: Data) -> [Data] {
        var parts: [Data] = []
        var searchStart = body.startIndex

        // Find first boundary
        guard let firstRange = body.range(of: boundary, in: searchStart..<body.endIndex) else {
            return []
        }

        // Move past the first boundary + \r\n
        searchStart = firstRange.upperBound
        if searchStart + 2 <= body.endIndex, body[searchStart] == 0x0D, body[searchStart + 1] == 0x0A {
            searchStart += 2
        }

        while searchStart < body.endIndex {
            guard let nextRange = body.range(of: boundary, in: searchStart..<body.endIndex) else {
                break
            }

            // Part content is between current position and next boundary
            // Strip trailing \r\n before the boundary
            var partEnd = nextRange.lowerBound
            if partEnd >= searchStart + 2,
               body[partEnd - 2] == 0x0D, body[partEnd - 1] == 0x0A {
                partEnd -= 2
            }

            if partEnd > searchStart {
                parts.append(Data(body[searchStart..<partEnd]))
            }

            // Move past this boundary
            searchStart = nextRange.upperBound
            // Check for closing `--` (end of multipart)
            if searchStart + 2 <= body.endIndex,
               body[searchStart] == 0x2D, body[searchStart + 1] == 0x2D {
                break
            }
            // Skip \r\n after boundary
            if searchStart + 2 <= body.endIndex,
               body[searchStart] == 0x0D, body[searchStart + 1] == 0x0A {
                searchStart += 2
            }
        }

        return parts
    }

    /// Returns `true` if the regex pattern matches any of the candidate strings.
    private static func regexMatchesAny(pattern: String, candidates: [String]) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        for text in candidates {
            if regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        return false
    }
}

// MARK: - URLPatternMatcher

/// Matches a URL path against a pattern string.
///
/// Pattern syntax
/// ==============
/// | Pattern                 | Meaning                                             |
/// |-------------------------|-----------------------------------------------------|
/// | `/api/users`            | Exact path match                                    |
/// | `/api/users/*`          | Wildcard – one non-`/` segment                      |
/// | `/api/**`               | Double wildcard – zero or more path segments        |
/// | `/api/users/{id}`       | Named path parameter (same as `*` for matching)     |
/// | `~^/api/users/[0-9]+$~` | Explicit regex (surrounded by `~` delimiters)       |
public struct URLPatternMatcher: Sendable {

    /// Returns `true` when `path` matches `pattern`.
    public static func matches(path: String, pattern: String) -> Bool {
        if pattern.hasPrefix("~") && pattern.hasSuffix("~") && pattern.count >= 2 {
            // Explicit regex mode
            let inner = String(pattern.dropFirst().dropLast())
            return regexMatches(path, pattern: inner)
        }

        // Convert glob-style pattern to a regex and match
        let regex = globToRegex(pattern)
        return regexMatches(path, pattern: regex)
    }

    // MARK: - Private helpers

    /// Converts a glob/template pattern to a regular expression string.
    ///
    /// - `{param}` → `[^/]+`
    /// - `**`      → `.*`
    /// - `*`       → `[^/]+`
    static func globToRegex(_ pattern: String) -> String {
        var result = "^"
        var idx = pattern.startIndex

        while idx < pattern.endIndex {
            let ch = pattern[idx]

            if ch == "{" {
                // Named parameter – match one segment
                if let closing = pattern[idx...].firstIndex(of: "}") {
                    result += "[^/]+"
                    idx = pattern.index(after: closing)
                    continue
                }
            } else if ch == "*" {
                let next = pattern.index(after: idx)
                if next < pattern.endIndex && pattern[next] == "*" {
                    // Double wildcard – match anything
                    result += ".*"
                    idx = pattern.index(after: next)
                    continue
                } else {
                    // Single wildcard – match one segment
                    result += "[^/]+"
                }
            } else {
                // Escape regex metacharacters
                result += NSRegularExpression.escapedPattern(for: String(ch))
            }

            idx = pattern.index(after: idx)
        }

        result += "$"
        return result
    }

    private static func regexMatches(_ string: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, range: range) != nil
    }
}
