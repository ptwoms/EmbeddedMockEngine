import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - MockServerError

public enum MockServerError: Error, Sendable {
    case socketCreationFailed(Int32)
    case socketOptionFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case alreadyRunning
    case notRunning
    case cancelled
    case tlsNotSupported
}

// MARK: - SocketReadWriter

/// Abstracts reading and writing over a socket so plain-TCP and TLS connections
/// can share the same HTTP parsing / serialisation logic.
protocol SocketReadWriter: AnyObject {
    /// Reads up to `maxLength` bytes. Returns `nil` on error or connection close.
    func read(maxLength: Int) -> Data?
    /// Writes all bytes of `data`.
    func write(_ data: Data)
    /// Performs any protocol-level shutdown (e.g. TLS close_notify).
    func close()
}

// MARK: - PlainSocketReadWriter

/// Plain (unencrypted) socket I/O using POSIX `recv` / `send`.
private final class PlainSocketReadWriter: SocketReadWriter {
    private let fd: Int32

    init(fd: Int32) { self.fd = fd }

    func read(maxLength: Int) -> Data? {
        var buf = [UInt8](repeating: 0, count: maxLength)
        let n = recv(fd, &buf, maxLength, 0)
        guard n > 0 else { return nil }
        return Data(buf[0..<n])
    }

    func write(_ data: Data) {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { ptr in
                send(fd, ptr.baseAddress!, ptr.count, 0)
            }
            guard written > 0 else { return }
            remaining = remaining.dropFirst(written)
        }
    }

    func close() {}
}

// MARK: - MockServer

/// A lightweight HTTP/1.x server built on POSIX sockets.
///
/// `MockServer` owns a listening socket and an `AsyncStream`-based accept loop
/// that runs on a dedicated OS thread so cooperative concurrency threads are
/// never blocked.  Each accepted connection is processed concurrently using
/// Swift's structured concurrency (a `TaskGroup`).
final class MockServer: @unchecked Sendable {

    // MARK: - State (protected by stateLock)

    private let stateLock = NSLock()
    private var serverFD: Int32 = -1
    private var _port: UInt16 = 0
    private var acceptThread: Thread?
    private var connectionsContinuation: AsyncStream<Int32>.Continuation?
    private var serverTask: Task<Void, Never>?

#if canImport(Security)
    private var tlsIdentityLoader: TLSIdentityLoader?
#endif

    var port: UInt16 {
        stateLock.withLock { _port }
    }

    var isRunning: Bool {
        stateLock.withLock { serverFD >= 0 }
    }

    // MARK: - Public interface

    /// Starts the server and returns the port it is listening on.
    ///
    /// - Parameters:
    ///   - port:           Port to bind to. Pass `0` to let the OS pick a free port.
    ///   - bindAddress:    Network interface to bind to (default: loopback).
    ///   - tls:            Optional TLS configuration. When provided the server
    ///                     accepts HTTPS connections with TLS 1.2 or newer.
    ///                     Requires Darwin (macOS / iOS); throws
    ///                     `MockServerError.tlsNotSupported` on other platforms.
    ///   - requestHandler: Closure called for every successfully parsed request.
    func start(
        port: UInt16,
        bindAddress: String = "127.0.0.1",
        tls: TLSConfiguration? = nil,
        requestHandler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) throws -> UInt16 {
#if canImport(Security)
        if let tls {
            let loader = try TLSIdentityLoader(
                certificateURL: tls.resolvedCertificateURL(relativeTo: nil),
                privateKeyURL:  tls.resolvedPrivateKeyURL(relativeTo: nil)
            )
            stateLock.withLock { tlsIdentityLoader = loader }
        }
#else
        if tls != nil { throw MockServerError.tlsNotSupported }
#endif

        try stateLock.withLock {
            guard serverFD < 0 else { throw MockServerError.alreadyRunning }

            let (fd, assignedPort) = try Self.makeListeningSocket(port: port, bindAddress: bindAddress)
            serverFD = fd
            _port = assignedPort
            return assignedPort
        }

        let fd = stateLock.withLock { serverFD }
        startAcceptLoop(serverFD: fd, requestHandler: requestHandler)
        return stateLock.withLock { _port }
    }

    /// Stops the server and waits for pending work to finish.
    func stop() {
        let fd = stateLock.withLock { () -> Int32 in
            let old = serverFD
            serverFD = -1
            _port = 0
            return old
        }

        // Close the server socket – this causes accept() to return with an error,
        // which terminates the accept loop thread.
        if fd >= 0 {
            closeSocket(fd)
        }

        connectionsContinuation?.finish()
        connectionsContinuation = nil

        serverTask?.cancel()
        serverTask = nil

#if canImport(Security)
        stateLock.withLock { tlsIdentityLoader }?.cleanup()
        stateLock.withLock { tlsIdentityLoader = nil }
#endif
    }

    // MARK: - Accept loop

    private func startAcceptLoop(
        serverFD: Int32,
        requestHandler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) {
        let (stream, continuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .unbounded)
        stateLock.withLock { connectionsContinuation = continuation }

        // Dedicated OS thread – does *not* consume a cooperative thread-pool slot.
        let thread = Thread {
            while true {
                let clientFD = accept(serverFD, nil, nil)
                guard clientFD >= 0 else {
                    // Retry interrupted accepts; stop on closure or fatal errors.
                    if errno == EINTR { continue }
                    continuation.finish()
                    return
                }
                continuation.yield(clientFD)
            }
        }
        thread.qualityOfService = .utility
        thread.start()

        stateLock.withLock { acceptThread = thread }

        // Structured-concurrency task – processes connections concurrently.
        serverTask = Task.detached(priority: .utility) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for await clientFD in stream {
                    guard !Task.isCancelled else {
                        closeSocket(clientFD)
                        break
                    }
                    group.addTask {
                        await self?.handle(clientFD: clientFD, requestHandler: requestHandler)
                    }
                }
            }
        }
    }

    // MARK: - Connection handling

    private func handle(
        clientFD: Int32,
        requestHandler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) async {
        defer { closeSocket(clientFD) }

        // Set a receive timeout so a slow/malicious client can't stall us.
        setReceiveTimeout(clientFD, seconds: 5)

        // Build the appropriate read/write wrapper (plain TCP or TLS).
        let io: SocketReadWriter
#if canImport(Security)
        if let identity = stateLock.withLock({ tlsIdentityLoader?.identity }) {
            guard let tlsIO = try? TLSSocketReadWriter(fd: clientFD, identity: identity) else {
                PlainSocketReadWriter(fd: clientFD).write(HTTPResponseSerializer.serialize(.badRequest()))
                return
            }
            io = tlsIO
        } else {
            io = PlainSocketReadWriter(fd: clientFD)
        }
#else
        io = PlainSocketReadWriter(fd: clientFD)
#endif

        defer { io.close() }

        guard
            let requestData = readHTTPRequest(from: io),
            let request = HTTPParser.parse(data: requestData)
        else {
            io.write(HTTPResponseSerializer.serialize(.badRequest()))
            return
        }

        let response = await requestHandler(request)
        io.write(HTTPResponseSerializer.serialize(response))
    }

    // MARK: - Socket I/O helpers

    /// Reads bytes from `io` until a complete HTTP request is accumulated.
    private func readHTTPRequest(from io: SocketReadWriter) -> Data? {
        var buffer = Data()

        while true {
            guard let chunk = io.read(maxLength: 4096), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if HTTPParser.isComplete(buffer) { break }
        }

        return buffer.isEmpty ? nil : buffer
    }

    /// Sets `SO_RCVTIMEO` on the socket to prevent indefinite blocking.
    private func setReceiveTimeout(_ fd: Int32, seconds: Int) {
#if canImport(Darwin)
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
#else
        var tv = timeval(tv_sec: __time_t(seconds), tv_usec: 0)
#endif
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - Socket creation

    private static func makeListeningSocket(port: UInt16, bindAddress: String = "127.0.0.1") throws -> (Int32, UInt16) {
#if canImport(Darwin)
        let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
#else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
#endif
        guard fd >= 0 else {
            throw MockServerError.socketCreationFailed(errno)
        }

        // Allow fast reuse of the port after a restart.
        var reuseVal: Int32 = 1
        if setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseVal, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            closeSocket(fd)
            throw MockServerError.socketOptionFailed(errno)
        }

        // Bind to the requested address.
        var addr = sockaddr_in()
        addr.sin_family  = sa_family_t(AF_INET)
        addr.sin_port    = port.bigEndian
        addr.sin_addr.s_addr = resolveBindAddress(bindAddress)

        let bindResult = withUnsafeBytes(of: &addr) { ptr in
            bind(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self),
                 socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        guard bindResult == 0 else {
            closeSocket(fd)
            throw MockServerError.bindFailed(errno)
        }

        guard listen(fd, 128) == 0 else {
            closeSocket(fd)
            throw MockServerError.listenFailed(errno)
        }

        // Discover the actual port (important when port == 0).
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutableBytes(of: &boundAddr) { ptr in
            _ = getsockname(fd, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &addrLen)
        }
        let assignedPort = UInt16(bigEndian: boundAddr.sin_port)

        return (fd, assignedPort)
    }

    // MARK: - Platform helpers

    /// Resolves a string bind address (e.g. `"127.0.0.1"`, `"0.0.0.0"`) to
    /// an `in_addr_t` suitable for `sockaddr_in.sin_addr.s_addr`.
    private static func resolveBindAddress(_ address: String) -> in_addr_t {
        if address == "0.0.0.0" {
            return in_addr_t(0) // INADDR_ANY
        }
        var inAddr = in_addr()
        if inet_pton(AF_INET, address, &inAddr) == 1 {
            return inAddr.s_addr
        }
        // Fallback to loopback
#if canImport(Darwin)
        return INADDR_LOOPBACK.bigEndian
#else
        return UInt32(0x7f000001).bigEndian
#endif
    }
}

// MARK: - Module-level helpers

@inline(__always)
private func closeSocket(_ fd: Int32) {
#if canImport(Darwin)
    _ = Darwin.close(fd)
#else
    _ = Glibc.close(fd)
#endif
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
