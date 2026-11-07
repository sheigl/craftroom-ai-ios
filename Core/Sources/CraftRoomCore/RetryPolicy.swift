import Foundation

/// Polling and retry policy for the remote engine (plan T3.3).
///
/// The service serialises one job at a time, so two things are normal and must
/// not surface as errors: a job waiting in the server queue, and a `503` when
/// desktop2's GPU is busy (`queue_full`, `vram_low`) or ComfyUI is momentarily
/// down (`comfyui_unavailable`). Both are retried with exponential backoff,
/// capped so an unreachable host is reported in a reasonable time.
public struct RetryPolicy: Equatable, Sendable {
    /// `GET /jobs/{id}` cadence for a running job.
    public var pollInterval: TimeInterval
    /// ± fraction applied to `pollInterval` so several clients (and the owner's
    /// curl) do not tick in lockstep.
    public var pollJitter: Double
    /// First backoff after a retryable failure.
    public var initialBackoff: TimeInterval
    /// Backoff ceiling.
    public var maxBackoff: TimeInterval
    /// Whole-operation budget: submit + poll + download.
    public var totalTimeout: TimeInterval

    public init(pollInterval: TimeInterval = 0.7,
                pollJitter: Double = 0.25,
                initialBackoff: TimeInterval = 2,
                maxBackoff: TimeInterval = 30,
                totalTimeout: TimeInterval = 600) {
        self.pollInterval = pollInterval
        self.pollJitter = pollJitter
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.totalTimeout = totalTimeout
    }

    public static let `default` = RetryPolicy()

    /// Delay before poll number `index` (0-based): nominal interval ± jitter,
    /// deterministic so a test (and a support report) can read the timeline.
    public func pollDelay(_ index: Int) -> TimeInterval {
        let factor = Self.jitterFactor(index)
        let scale = 1 + pollJitter * factor
        return max(0, pollInterval * scale)
    }

    /// `2, 4, 8, 16, 30, 30…` seconds for attempt 1, 2, 3…
    public func backoff(attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return 0 }
        var value = initialBackoff
        var n = 1
        while n < attempt && value < maxBackoff {
            value *= 2
            n += 1
        }
        return min(value, maxBackoff)
    }

    /// Stable value in `[-1, 1]` for an index (no RNG state, no wall clock).
    public static func jitterFactor(_ index: Int) -> Double {
        let x = UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15
        let mixed = x ^ (x >> 29) ^ (x >> 43)
        let unit = Double(mixed % 1000) / 1000.0       // [0, 1)
        return unit * 2 - 1
    }

    /// Error codes worth retrying. `invalid_input` and `unknown_job` are not:
    /// both need a new request, not a wait.
    public static func retryable(code: String?) -> Bool {
        switch code ?? "" {
        case "comfyui_unavailable", "queue_full", "model_unavailable", "vram_low":
            return true
        case "internal", "":
            // A bare 503 without a code usually means a proxy/tunnel; retry.
            return true
        default:
            return false
        }
    }

    /// Transport-level failures (`URLError`, timeouts) are retried; an HTTP
    /// status is only retried when it is a 503 with a retryable code.
    public static func retryable(status: Int, code: String?) -> Bool {
        status == 503 && retryable(code: code)
    }
}
