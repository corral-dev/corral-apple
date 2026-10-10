import XCTest
@testable import Corral

final class OneShotThrowingContinuationTests: XCTestCase {
    func testDuplicateSuccessCallbacksResumeOnlyOnce() async throws {
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            let gate = OneShotThrowingContinuation(continuation)
            gate.resume(returning: 7)
            gate.resume(returning: 99)
            gate.resume(throwing: URLError(.networkConnectionLost))
        }
        XCTAssertEqual(value, 7)
    }

    func testErrorThenSuccessDoesNotDoubleResume() async {
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = OneShotThrowingContinuation(continuation)
                gate.resume(throwing: URLError(.timedOut))
                gate.resume()
                gate.resume(throwing: URLError(.badServerResponse))
            }
            XCTFail("expected first error to win")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
