import XCTest
@testable import EmbeddedMockEngine

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class MockServerTests: XCTestCase {
    func test_shouldContinueAcceptLoop_trueForEINTR() {
        XCTAssertTrue(MockServer.shouldContinueAcceptLoop(afterAcceptError: EINTR))
    }

    func test_shouldContinueAcceptLoop_falseForNonEINTR() {
        let nonInterruptingErrors: [Int32] = [
            EINVAL,
            EAGAIN,
            EWOULDBLOCK,
            ECONNABORTED,
            EMFILE
        ]

        for error in nonInterruptingErrors {
            XCTAssertFalse(MockServer.shouldContinueAcceptLoop(afterAcceptError: error))
        }
    }
}
