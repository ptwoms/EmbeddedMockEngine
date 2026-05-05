#if canImport(Security)
import Security
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - TLS errors

enum TLSError: Error {
    case certificateLoadFailed
    case privateKeyLoadFailed
    case identityCreationFailed
    case contextCreationFailed
    case handshakeFailed(OSStatus)
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
}

// MARK: - PEM / DER helpers

/// Extracts the Base64-encoded body from a PEM block and decodes it to DER bytes.
/// Tries multiple common PEM labels (PRIVATE KEY, RSA PRIVATE KEY, EC PRIVATE KEY).
private func pemToDER(pem: String, labels: [String]) -> Data? {
    for label in labels {
        let begin = "-----BEGIN \(label)-----"
        let end   = "-----END \(label)-----"
        guard
            let startRange = pem.range(of: begin),
            let endRange   = pem.range(of: end)
        else { continue }
        let b64 = String(pem[startRange.upperBound..<endRange.lowerBound])
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        if let data = Data(base64Encoded: b64) { return data }
    }
    return nil
}

// MARK: - TLSIdentityLoader

/// Loads a `SecIdentity` from separate certificate and private-key files on Darwin.
///
/// Temporarily stores the certificate and key in the default keychain so that
/// the OS can pair them into an identity. Both items are deleted when `cleanup()`
/// is called (e.g. when the server stops).
final class TLSIdentityLoader {

    private let certTag: Data
    private var certAdded = false
    private var keyAdded  = false

    private(set) var identity: SecIdentity?

    init(certificateURL: URL, privateKeyURL: URL) throws {
        // Unique tag to avoid collisions with any existing keychain items.
        certTag = Data(UUID().uuidString.utf8)
        identity = try Self.loadIdentity(
            certURL: certificateURL,
            keyURL: privateKeyURL,
            tag: certTag
        )
    }

    /// Removes the temporarily-added keychain items.
    func cleanup() {
        // Delete by the application tag we used when adding.
        let deleteKey: [CFString: Any] = [
            kSecClass:              kSecClassKey,
            kSecAttrApplicationTag: certTag
        ]
        SecItemDelete(deleteKey as CFDictionary)

        let deleteCert: [CFString: Any] = [
            kSecClass:              kSecClassCertificate,
            kSecAttrApplicationTag: certTag
        ]
        SecItemDelete(deleteCert as CFDictionary)
    }

    // MARK: - Private

    private static func loadIdentity(certURL: URL, keyURL: URL, tag: Data) throws -> SecIdentity {
        // --- Load certificate ---
        let certData = try Data(contentsOf: certURL)
        let certDER: Data
        if let pem = String(data: certData, encoding: .utf8),
           let der = pemToDER(pem: pem, labels: ["CERTIFICATE"]) {
            certDER = der
        } else {
            certDER = certData  // assume raw DER
        }
        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw TLSError.certificateLoadFailed
        }

        // --- Load private key ---
        let keyData = try Data(contentsOf: keyURL)
        let keyDER: Data
        if let pem = String(data: keyData, encoding: .utf8),
           let der = pemToDER(pem: pem, labels: ["PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY"]) {
            keyDER = der
        } else {
            keyDER = keyData  // assume raw DER
        }

        // Try RSA first, then EC.
        let privateKey = try makePrivateKey(der: keyDER)

        // --- Add key to keychain (temporary, tagged for cleanup) ---
        let keyAddQuery: [CFString: Any] = [
            kSecClass:              kSecClassKey,
            kSecAttrApplicationTag: tag,
            kSecAttrKeyClass:       kSecAttrKeyClassPrivate,
            kSecValueRef:           privateKey
        ]
        let keyStatus = SecItemAdd(keyAddQuery as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw TLSError.identityCreationFailed
        }

        // --- Add certificate to keychain ---
        let certAddQuery: [CFString: Any] = [
            kSecClass:    kSecClassCertificate,
            kSecValueRef: cert
        ]
        let certStatus = SecItemAdd(certAddQuery as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw TLSError.identityCreationFailed
        }

        // --- Obtain the identity (cert + private key pair) ---
        return try findIdentity(for: cert)
    }

    /// Creates a `SecKey` from raw DER bytes, trying RSA then EC.
    private static func makePrivateKey(der: Data) throws -> SecKey {
        for keyType in [kSecAttrKeyTypeRSA, kSecAttrKeyTypeEC] as [CFString] {
            let attrs: [CFString: Any] = [
                kSecAttrKeyType:  keyType,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate
            ]
            var error: Unmanaged<CFError>?
            if let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) {
                return key
            }
        }
        throw TLSError.privateKeyLoadFailed
    }

    /// Finds the identity whose embedded certificate matches `cert`.
    private static func findIdentity(for cert: SecCertificate) throws -> SecIdentity {
        let certBytes = SecCertificateGetData(cert) as Data

        // On macOS, prefer the direct API.
#if os(macOS)
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, cert, &identity)
        if status == errSecSuccess, let identity {
            return identity
        }
#endif

        // Fallback: query all identities and match by certificate bytes.
        let query: [CFString: Any] = [
            kSecClass:      kSecClassIdentity,
            kSecReturnRef:  true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status2 = SecItemCopyMatching(query as CFDictionary, &result)
        guard status2 == errSecSuccess, let items = result as? [SecIdentity] else {
            throw TLSError.identityCreationFailed
        }
        for item in items {
            var itemCert: SecCertificate?
            guard SecIdentityCopyCertificate(item, &itemCert) == errSecSuccess,
                  let itemCert else { continue }
            if (SecCertificateGetData(itemCert) as Data) == certBytes {
                return item
            }
        }
        throw TLSError.identityCreationFailed
    }
}

// MARK: - TLSSocketReadWriter

/// Implements `SocketReadWriter` using SecureTransport over a plain TCP socket.
///
/// - Important: `SecureTransport` is deprecated as of macOS 10.15 / iOS 13.0 but
///   remains fully functional in later OS versions and is the only way to add TLS
///   on top of POSIX sockets without pulling in `Network.framework` or external
///   dependencies. Deprecation warnings are suppressed intentionally.
@available(macOS, deprecated: 10.15, message: "SecureTransport deprecated; TLS still functional")
@available(iOS,   deprecated: 13.0,  message: "SecureTransport deprecated; TLS still functional")
final class TLSSocketReadWriter: SocketReadWriter {

    private let ctx: SSLContext
    private let fd: Int32

    /// Performs the TLS handshake and returns a ready-to-use `TLSSocketReadWriter`.
    init(fd: Int32, identity: SecIdentity) throws {
        self.fd = fd

        guard let ctx = SSLCreateContext(nil, .serverSide, .streamType) else {
            throw TLSError.contextCreationFailed
        }
        self.ctx = ctx

        // Attach the socket FD as the I/O connection reference.
        SSLSetConnection(ctx, UnsafeRawPointer(bitPattern: Int(fd)))

        // Provide the server's certificate identity (cert + private key).
        let certArray = [identity] as CFArray
        SSLSetCertificate(ctx, certArray)

        // Require TLS 1.2 or newer.
        SSLSetProtocolVersionMin(ctx, .TLSProtocol12)

        // Wire up POSIX recv/send as the underlying transport.
        SSLSetIOFuncs(ctx, tlsRead, tlsWrite)

        // Perform handshake (may return errSSLWouldBlock; loop until done).
        var status: OSStatus
        repeat {
            status = SSLHandshake(ctx)
        } while status == errSSLWouldBlock

        guard status == errSecSuccess else {
            SSLClose(ctx)
            throw TLSError.handshakeFailed(status)
        }
    }

    func read(maxLength: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: maxLength)
        var processed = 0
        let status = SSLRead(ctx, &buf, maxLength, &processed)
        guard (status == errSecSuccess || status == errSSLWouldBlock) && processed > 0 else {
            return nil
        }
        return Data(buf[0..<processed])
    }

    func write(_ data: Data) {
        var remaining = data
        while !remaining.isEmpty {
            var processed = 0
            let status = remaining.withUnsafeBytes { ptr in
                SSLWrite(ctx, ptr.baseAddress!, ptr.count, &processed)
            }
            guard status == errSecSuccess || status == errSSLWouldBlock, processed > 0 else { return }
            remaining = remaining.dropFirst(processed)
        }
    }

    func close() {
        SSLClose(ctx)
    }
}

// MARK: - C-compatible I/O callbacks for SecureTransport

/// SecureTransport read callback — reads from the raw socket FD.
private let tlsRead: SSLReadFunc = { connection, data, dataLength in
    let fd = Int32(bitPattern: UInt(bitPattern: connection))
    let n  = Darwin.recv(fd, data!, dataLength.pointee, 0)
    if n > 0 {
        dataLength.pointee = n
        return errSecSuccess
    } else if n == 0 {
        dataLength.pointee = 0
        return errSSLClosedGraceful
    } else {
        dataLength.pointee = 0
        if errno == EAGAIN || errno == EWOULDBLOCK { return errSSLWouldBlock }
        return errSecIO
    }
}

/// SecureTransport write callback — writes to the raw socket FD.
private let tlsWrite: SSLWriteFunc = { connection, data, dataLength in
    let fd = Int32(bitPattern: UInt(bitPattern: connection))
    let n  = Darwin.send(fd, data!, dataLength.pointee, 0)
    if n > 0 {
        dataLength.pointee = n
        return errSecSuccess
    } else if n == 0 {
        dataLength.pointee = 0
        return errSSLClosedGraceful
    } else {
        dataLength.pointee = 0
        if errno == EAGAIN || errno == EWOULDBLOCK { return errSSLWouldBlock }
        return errSecIO
    }
}

#endif // canImport(Security)
