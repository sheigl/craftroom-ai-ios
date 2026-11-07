import Foundation
import CraftRoomCore

/// `URLSession` implementation of `CraftRoomCore.HTTPTransport`.
///
/// Two deliberate choices:
///
///  * `waitsForConnectivity = false` — an unreachable desktop2 must fail in
///    seconds with an actionable error, not sit on a spinner waiting for the
///    network to appear (plan acceptance criterion 3);
///  * generous per-request timeouts for the multipart upload of a photo on
///    Wi-Fi, shorter for the JSON polls (the poll loop retries anyway).
///
/// ATS: `project.yml` carries exceptions for the LAN hosts the app talks to
/// (192.168.68.83 payload server, 192.168.68.92 generation server).
final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let uploadSession: URLSession

    init(requestTimeout: TimeInterval = 20, uploadTimeout: TimeInterval = 90) {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = requestTimeout * 2
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: cfg)

        let uploadCfg = URLSessionConfiguration.default
        uploadCfg.timeoutIntervalForRequest = uploadTimeout
        uploadCfg.timeoutIntervalForResource = uploadTimeout
        uploadCfg.waitsForConnectivity = false
        uploadSession = URLSession(configuration: uploadCfg)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body

        let chosen = request.method == "POST" ? uploadSession : session
        let (data, response) = try await chosen.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
