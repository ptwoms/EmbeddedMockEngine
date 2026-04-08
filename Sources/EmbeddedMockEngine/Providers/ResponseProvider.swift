import Foundation

// MARK: - ResponseProvider

/// Resolves the body of a ``MockResponseDefinition`` into raw `Data`.
///
/// Resolution order
/// ================
/// 1. `bodyFile` — path resolved relative to `baseURL` (file system) **or**
///    looked up as a resource in `bundle`.
/// 2. `body`     — the inline string encoded as UTF-8.
/// 3. Returns `nil` if neither is set.
public struct ResponseProvider: Sendable {

    // MARK: - Dependencies

    /// Directory used as the base for relative `bodyFile` paths.
    public let baseURL: URL?

    /// Bundle searched for `bodyFile` resources when `baseURL` is nil or the
    /// file is not found at the file-system path.
    public let bundle: Bundle?

    // MARK: - Init

    public init(baseURL: URL? = nil, bundle: Bundle? = nil) {
        self.baseURL = baseURL
        self.bundle = bundle
    }

    // MARK: - Body resolution

    /// Resolves the body for `definition`, returning the raw bytes (or `nil`).
    public func resolveBody(for definition: MockResponseDefinition) -> Data? {
        if let filePath = definition.bodyFile {
            return loadFile(path: filePath)
        }
        return definition.body.flatMap { $0.data(using: .utf8) }
    }

    /// Resolves the full ``HTTPResponse`` for `definition`.
    public func resolve(definition: MockResponseDefinition) -> HTTPResponse {
        let body = resolveBody(for: definition)
        var headers = definition.headers ?? [:]

        // Auto-detect Content-Type if not provided
        if headers["Content-Type"] == nil, let path = definition.bodyFile {
            headers["Content-Type"] = contentType(forPath: path)
        }

        return HTTPResponse(statusCode: definition.statusCode, headers: headers, body: body)
    }

    // MARK: - File loading

    private func loadFile(path: String) -> Data? {
        // 1. Try as an absolute path first
        if path.hasPrefix("/") {
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }

        // 2. Try relative to baseURL
        if let base = baseURL {
            let fileURL = base.appendingPathComponent(path)
            if let data = try? Data(contentsOf: fileURL) {
                return data
            }
        }

        // 3. Try inside the bundle
        if let data = loadFromBundle(path: path) {
            return data
        }

        return nil
    }

    private func loadFromBundle(path: String) -> Data? {
        guard let bundle = bundle else { return nil }

        // Attempt with path components (e.g. "Responses/users.json")
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        let ext  = url.pathExtension

        if let resourceURL = bundle.url(forResource: name, withExtension: ext.isEmpty ? nil : ext) {
            return try? Data(contentsOf: resourceURL)
        }

        // Fallback: full subpath search within the bundle
        if let bundleURL = bundle.resourceURL {
            let candidate = bundleURL.appendingPathComponent(path)
            return try? Data(contentsOf: candidate)
        }

        return nil
    }

    // MARK: - Content-Type inference

    private func contentType(forPath path: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "json":  return "application/json"
        case "xml":   return "application/xml"
        case "html":  return "text/html; charset=utf-8"
        case "txt":   return "text/plain; charset=utf-8"
        case "csv":   return "text/csv"
        default:      return "application/octet-stream"
        }
    }
}
