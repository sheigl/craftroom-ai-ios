import XCTest
@testable import CraftRoomCore

/// Polling/backoff policy: the numbers the app will live with against a
/// one-job server on a shared GPU, including the 10-minute ceiling.
final class RetryPolicyTests: XCTestCase {
    func testDefaultsMatchThePlan() {
        let policy = RetryPolicy.default
        XCTAssertEqual(policy.pollInterval, 0.7, accuracy: 1e-9)
        XCTAssertEqual(policy.maxBackoff, 30, accuracy: 1e-9)
        XCTAssertEqual(policy.totalTimeout, 600, accuracy: 1e-9)
    }

    func testBackoffDoublesAndCapsAtThirtySeconds() {
        let policy = RetryPolicy.default
        let expected: [TimeInterval] = [2, 4, 8, 16, 30, 30, 30]
        for (index, seconds) in expected.enumerated() {
            XCTAssertEqual(policy.backoff(attempt: index + 1), seconds,
                           "attempt \(index + 1)")
        }
        XCTAssertEqual(policy.backoff(attempt: 0), 0)
        XCTAssertEqual(policy.backoff(attempt: -3), 0)
        XCTAssertLessThanOrEqual(policy.backoff(attempt: 100), policy.maxBackoff)
    }

    func testPollDelayIsJitteredButBounded() {
        let policy = RetryPolicy.default
        var seen = Set<String>()
        for index in 0..<200 {
            let delay = policy.pollDelay(index)
            XCTAssertGreaterThanOrEqual(delay, 0.7 * 0.75 - 1e-9)
            XCTAssertLessThanOrEqual(delay, 0.7 * 1.25 + 1e-9)
            seen.insert(String(format: "%.6f", delay))
        }
        // It really is jitter, not a constant.
        XCTAssertGreaterThan(seen.count, 50)
        // …and deterministic for the same index (a support report is readable).
        XCTAssertEqual(policy.pollDelay(7), policy.pollDelay(7))
        XCTAssertNotEqual(RetryPolicy.jitterFactor(1), RetryPolicy.jitterFactor(2))
    }

    func testOnlyTransientServerErrorsAreRetried() {
        for code in ["comfyui_unavailable", "queue_full", "model_unavailable",
                     "vram_low", "internal", ""] {
            XCTAssertTrue(RetryPolicy.retryable(code: code), code)
        }
        for code in ["invalid_input", "unknown_job", "job_failed", "nonsense"] {
            XCTAssertFalse(RetryPolicy.retryable(code: code), code)
        }
        XCTAssertTrue(RetryPolicy.retryable(status: 503, code: "queue_full"))
        XCTAssertFalse(RetryPolicy.retryable(status: 503, code: "invalid_input"))
        XCTAssertFalse(RetryPolicy.retryable(status: 422, code: "invalid_input"))
        XCTAssertFalse(RetryPolicy.retryable(status: 500, code: "internal"))
    }

    func testBudgetCountsInjectedSleepsSoTestsAndRealRunsAgree() {
        var budget = RemoteEngine.Budget(limit: 10)
        XCTAssertEqual(budget.remaining, 10, accuracy: 1e-6)
        XCTAssertEqual(budget.charge(4), 4, accuracy: 1e-6)
        XCTAssertEqual(budget.charge(40), 6, accuracy: 1e-6)   // capped
        XCTAssertEqual(budget.remaining, 0, accuracy: 1e-6)
    }
}
