import Foundation

/// Wireless telemetry for the unattended T5 ladder (build 9, no USB cable).
///
/// Every line that lands in `Documents/ladder.log` is also POSTed as
/// `text/plain` to the LAN log collector (`serve_payload.py do_POST /log`,
/// appended to `logs/ladder_device.log`), so the orchestrator can tail the
/// ladder from the Linux box while the iPad lies unlocked on the table.
///
/// Contract: **fire-and-forget for the caller, ordered on the wire** (build 10).
/// Build 9 POSTed each line from its own detached `Task`, so the collector saw
/// them in completion order — the 12 `CELL` lines of one moment arrived
/// shuffled, which makes a timeline unreadable. Now every line goes through one
/// serial queue and each request finishes (or times out) before the next one
/// starts, so the file matches the log. Still: a short timeout, errors
/// swallowed, no caller ever blocks. If the server is down the file log holds
/// everything and a pdm3 pull remains the fallback.
enum Telemetry {
    static let endpoint = "http://192.168.68.83:8123/log"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: cfg)
    }()

    /// One serial queue == wire order == log order.
    private static let queue = DispatchQueue(label: "craftroom.telemetry",
                                             qos: .utility,
                                             target: .global(qos: .utility))

    /// Lines handed to the collector and lines that completed, both counted on
    /// the serial queue itself (no lock needed, no torn reads).
    private(set) static var sent = 0
    private(set) static var attempted = 0

    /// Queue one line for delivery; return immediately. Never throws.
    static func send(_ line: String) {
        guard let url = URL(string: endpoint),
              let body = line.data(using: .utf8) else { return }
        queue.async {
            attempted += 1
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let sem = DispatchSemaphore(value: 0)
            let task = session.dataTask(with: request) { _, _, _ in sem.signal() }
            task.resume()
            // Bounded wait so a dead server cannot stall the queue behind the
            // 10 s resource timeout of a slow connection.
            if sem.wait(timeout: .now() + 12) == .success { sent += 1 } else { task.cancel() }
        }
    }

    /// `telemetry: 41/41 lines delivered` — the honest statement of whether the
    /// orchestrator's tail is complete.
    static var deliverySummary: String {
        "telemetry: \(sent)/\(attempted) lines delivered to \(endpoint)"
    }

    /// Give the queued lines a moment to leave the device (used right before
    /// the ladder writes its final marker, so the tail of a run is not lost).
    static func flush(timeout: TimeInterval = 12) {
        let sem = DispatchSemaphore(value: 0)
        queue.asyncAfter(deadline: .now() + 0.2) { sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
    }
}
