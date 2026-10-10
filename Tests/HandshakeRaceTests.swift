import XCTest
@testable import Corral

/// Cancellation-safe handshake racing: losers and late winners must be closed,
/// the arbiter must only wait for the first winner, and adopt/close must be exclusive.
final class HandshakeRaceTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    // MARK: HandshakeSocketLifecycle

    func testAdoptWinsOverLaterClose() {
        let closes = Counter()
        let lifecycle = HandshakeSocketLifecycle { closes.bump() }
        XCTAssertTrue(lifecycle.adopt())
        XCTAssertFalse(lifecycle.close())
        lifecycle.expire()
        XCTAssertEqual(closes.value, 0, "an adopted socket must never be closed by the race")
        XCTAssertEqual(lifecycle.currentPhase, .adopted)
        XCTAssertFalse(lifecycle.didTimeOut)
    }

    func testCloseBeforeAdoptRejectsAdoptionAndClosesOnce() {
        let closes = Counter()
        let lifecycle = HandshakeSocketLifecycle { closes.bump() }
        XCTAssertTrue(lifecycle.close())
        XCTAssertFalse(lifecycle.close())
        lifecycle.expire()
        XCTAssertFalse(lifecycle.adopt(), "a handshake that finished after cancellation must not become the winner")
        XCTAssertEqual(closes.value, 1)
        XCTAssertEqual(lifecycle.currentPhase, .closed)
    }

    func testExpireMarksTimeoutAndClosesSocketImmediately() {
        let closes = Counter()
        let lifecycle = HandshakeSocketLifecycle { closes.bump() }
        lifecycle.expire()
        XCTAssertEqual(closes.value, 1, "timeout must close the socket right away, not wait for the receive to return")
        XCTAssertTrue(lifecycle.didTimeOut)
        XCTAssertFalse(lifecycle.adopt())
    }

    // MARK: HandshakeArbiter

    private final class Discards: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }
        var all: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testFirstWinnerReturnsWithoutWaitingForHangingLoser() async throws {
        let discards = Discards()
        let arbiter = HandshakeArbiter<Int> { discards.add($0) }
        let loserCancelled = expectation(description: "hanging loser gets cancelled")
        arbiter.launch {
            // Simulates a candidate whose receive never returns on its own.
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                loserCancelled.fulfill()
                throw error
            }
            return 2
        }
        arbiter.launch {
            try await Task.sleep(for: .milliseconds(20))
            return 1
        }
        let started = Date()
        let win = try await arbiter.awaitWinner(overallTimeout: 5)
        XCTAssertEqual(win, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "must not wait for the hanging loser")
        await fulfillment(of: [loserCancelled], timeout: 2)
        XCTAssertEqual(discards.all, [])
    }

    func testLateWinnerIsDiscarded() async throws {
        let discards = Discards()
        let arbiter = HandshakeArbiter<Int> { discards.add($0) }
        let lateFinished = expectation(description: "late candidate finishes")
        arbiter.launch {
            try await Task.sleep(for: .milliseconds(10))
            return 1
        }
        arbiter.launch {
            // Ignores cancellation, like a socket whose receive completes after cancelAll.
            try? await Task.sleep(for: .milliseconds(150))
            defer { lateFinished.fulfill() }
            return 2
        }
        let win = try await arbiter.awaitWinner(overallTimeout: 5)
        XCTAssertEqual(win, 1)
        await fulfillment(of: [lateFinished], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(discards.all, [2], "a winner arriving after settlement must be closed, never leaked")
    }

    func testAllFailuresThrowLastNonCancellationError() async {
        let arbiter = HandshakeArbiter<Int> { _ in }
        // Deterministic completion order without sleeps: attempt B awaits
        // attempt A's task handle, so fail(B) strictly happens after fail(A)
        // (the handle completes only after A's offer/fail ran), and the arbiter
        // must surface the last actual non-cancellation failure, "b". A fixed
        // delay cannot establish this: under full-suite load a detached task's
        // first run can slip past any sleep and invert completion order.
        // Both launches are registered before A is released, so launched == 2
        // before either attempt can fail.
        let (releaseA, releaseAContinuation) = AsyncStream<Void>.makeStream()
        let attemptA = arbiter.launch {
            var iterator = releaseA.makeAsyncIterator()
            await iterator.next()
            throw RemoteClient.ConnectionError.handshakeFailed("a")
        }
        guard let attemptA else {
            return XCTFail("attempt A was not registered")
        }
        arbiter.launch {
            await attemptA.value
            throw RemoteClient.ConnectionError.handshakeFailed("b")
        }
        releaseAContinuation.yield()
        do {
            _ = try await arbiter.awaitWinner(overallTimeout: 5)
            XCTFail("expected failure")
        } catch let error as RemoteClient.ConnectionError {
            guard case let .handshakeFailed(message) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(message, "b")
        } catch {
            XCTFail("unexpected error \(error)")
        }
        releaseAContinuation.finish()
    }

    func testOverallTimeoutCancelsAttempts() async {
        let arbiter = HandshakeArbiter<Int> { _ in }
        let cancelled = expectation(description: "attempt cancelled by overall timeout")
        arbiter.launch {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.fulfill()
                throw error
            }
            return 1
        }
        do {
            _ = try await arbiter.awaitWinner(overallTimeout: 0.1)
            XCTFail("expected timeout")
        } catch let error as RemoteClient.ConnectionError {
            guard case .timeout = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testCallerCancellationCancelsAttemptsAndDiscardsPendingWinner() async {
        let discards = Discards()
        let arbiter = HandshakeArbiter<Int> { discards.add($0) }
        let attemptCancelled = expectation(description: "attempt cancelled")
        arbiter.launch {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                attemptCancelled.fulfill()
                throw error
            }
            return 1
        }
        let waiter = Task {
            try await arbiter.awaitWinner(overallTimeout: 30)
        }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error \(error)")
        }
        await fulfillment(of: [attemptCancelled], timeout: 2)
    }

    func testNoCandidatesFailsImmediately() async {
        let arbiter = HandshakeArbiter<Int> { _ in }
        do {
            _ = try await arbiter.awaitWinner(overallTimeout: 5)
            XCTFail("expected failure")
        } catch let error as RemoteClient.ConnectionError {
            guard case .handshakeFailed = error else { return XCTFail("unexpected error \(error)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
