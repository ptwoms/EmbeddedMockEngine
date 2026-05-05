import Foundation

// MARK: - TLSConfiguration

/// Configuration for enabling HTTPS (TLS 1.2+) on the mock server.
///
/// Provide paths to your PEM or DER certificate and private-key files:
/// ```swift
/// let tls = TLSConfiguration(
///     certificateFile: URL(fileURLWithPath: "/path/to/server.crt"),
///     privateKeyFile:  URL(fileURLWithPath: "/path/to/server.key")
/// )
/// let port = try await engine.start(tls: tls)
/// print("Mock server on https://localhost:\(port)")
/// ```
///
/// When encoded as part of a JSON configuration, paths are resolved relative
/// to the directory that contains the config file.
public struct TLSConfiguration: Codable, Sendable {
    /// Path to the PEM or DER certificate file.
    public let certificateFile: String
    /// Path to the PEM or DER private-key file.
    public let privateKeyFile: String

    // MARK: - Init

    /// Creates a TLS configuration from string paths.
    ///
    /// - Parameters:
    ///   - certificateFile: Absolute or config-relative path to the certificate.
    ///   - privateKeyFile:  Absolute or config-relative path to the private key.
    public init(certificateFile: String, privateKeyFile: String) {
        self.certificateFile = certificateFile
        self.privateKeyFile  = privateKeyFile
    }

    /// Creates a TLS configuration from `URL` values.
    ///
    /// - Parameters:
    ///   - certificateFile: `URL` pointing to the certificate file.
    ///   - privateKeyFile:  `URL` pointing to the private-key file.
    public init(certificateFile: URL, privateKeyFile: URL) {
        self.certificateFile = certificateFile.path
        self.privateKeyFile  = privateKeyFile.path
    }

    // MARK: - Internal helpers

    /// Resolves `certificateFile` against an optional base directory.
    func resolvedCertificateURL(relativeTo base: URL?) -> URL {
        resolve(certificateFile, relativeTo: base)
    }

    /// Resolves `privateKeyFile` against an optional base directory.
    func resolvedPrivateKeyURL(relativeTo base: URL?) -> URL {
        resolve(privateKeyFile, relativeTo: base)
    }

    private func resolve(_ path: String, relativeTo base: URL?) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return base?.appendingPathComponent(path) ?? URL(fileURLWithPath: path)
    }
}
