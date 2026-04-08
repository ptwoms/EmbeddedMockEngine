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
/// - **bodyPattern**     : the request body (UTF-8) must match the regex.
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
            guard let bodyData = request.body,
                  let bodyText = String(data: bodyData, encoding: .utf8) else { return false }
            guard (try? NSRegularExpression(pattern: bodyPattern))?.firstMatch(
                in: bodyText,
                range: NSRange(bodyText.startIndex..., in: bodyText)
            ) != nil else { return false }
        }

        return true
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
