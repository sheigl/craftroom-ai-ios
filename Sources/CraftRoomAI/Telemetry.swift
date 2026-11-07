import Foundation

/// Wireless telemetry for the unattended T5 ladder (build 9, no USB cable).
///
/// Every line that lands in `Documents/ladder.log` is also POSTed as
/// `text/plain` to the LAN log collector (`serve_payload.py do_POST /log`,
/// appended to `logs/ladder_device.log`), so the orchestrator can tail the
/// ladder from the Linux box while the iPad lies unlocked on the table.
///
/// Contract: **fire-and-forget**. A short timeout, a background task, errors
/// swallowed — telemetry can never block, delay or fail a ladder cell. If the
/// server is down the file log still holds everything and pdm3 pull remains
/// the fallback.
enum Telemetry {
    static let endpoint = "http://192.168.68.83:8123/log"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 10
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// POST one line in the background; return immediately. Never throws.
    static func send(_ line: String) {
        guard let url = URL(string: endpoint),
              let body = line.data(using: .utf8) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        Task.detached(priority: .background) {
            _ = try? await session.data(for: request)
        }
    }
}
