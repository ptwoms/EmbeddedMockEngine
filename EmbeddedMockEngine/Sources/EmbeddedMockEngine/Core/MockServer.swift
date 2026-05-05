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

    var port: UInt16 {
        stateLock.withLock { _port }
    }

    var isRunning: Bool {
        stateLock.withLock { serverFD >= 0 }
    }

    // MARK: - Public interface

    /// Starts the server and returns the port it is listening on.
    /// Pass `port: 0` to let the OS pick a free port.
    /// Pass `bindAddress` to control which interface to listen on (default: loopback).
    func start(
        port: UInt16,
        bindAddress: String = "127.0.0.1",
        requestHandler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) throws -> UInt16 {
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

        guard
            let requestData = readHTTPRequest(from: clientFD),
            let request = HTTPParser.parse(data: requestData)
        else {
            let response = HTTPResponseSerializer.serialize(.badRequest())
            writeAll(fd: clientFD, data: response)
            return
        }

        let response = await requestHandler(request)
        let responseData = HTTPResponseSerializer.serialize(response)
        writeAll(fd: clientFD, data: responseData)
    }

    // MARK: - Socket I/O helpers

    /// Reads bytes from `fd` until a complete HTTP request is accumulated.
    private func readHTTPRequest(from fd: Int32) -> Data? {
        var buffer = Data()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let bytesRead = recv(fd, &chunk, chunkSize, 0)
            if bytesRead <= 0 { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])
            if HTTPParser.isComplete(buffer) { break }
        }

        return buffer.isEmpty ? nil : buffer
    }

    /// Writes all bytes of `data` to `fd`.
    private func writeAll(fd: Int32, data: Data) {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { ptr in
                send(fd, ptr.baseAddress!, ptr.count, 0)
            }
            guard written > 0 else { return }
            remaining = remaining.dropFirst(written)
        }
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
