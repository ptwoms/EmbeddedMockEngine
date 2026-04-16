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
        XCTAssertFalse(MockServer.shouldContinueAcceptLoop(afterAcceptError: EINVAL))
    }
}
