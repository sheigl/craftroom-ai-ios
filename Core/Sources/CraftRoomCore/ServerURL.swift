import Foundation

/// Base-URL handling for the local generation server (desktop2, port 8124).
///
/// The owner types this in Settings on an iPad keyboard, so parsing is lenient
/// about the things people really type (`192.168.68.92:8124`, a trailing
/// slash, stray spaces) and strict about the things that would silently send a
/// request to the wrong place (no scheme, a non-HTTP scheme, no host, a query
/// string).
public enum ServerURL {
    /// Baked LAN default: the deployed `sdxl/api` service on desktop2.
    public static let defaultBase = "http://192.168.68.92:8124"

    public static var `default`: URL {
        // The constant above is validated by the unit tests.
        guard let url = URL(string: defaultBase) else {
            preconditionFailure("defaultBase is not a URL")
        }
        return url
    }

    public enum Invalid: Error, Equatable, LocalizedError {
        case empty
        case unsupportedScheme(String)
        case missingHost
        case malformed

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter the server address, e.g. http://192.168.68.92:8124"
            case .unsupportedScheme(let scheme):
                return "\(scheme):// is not supported — the server speaks plain http."
            case .missingHost:
                return "That address has no host. Use e.g. http://192.168.68.92:8124"
            case .malformed:
                return "That does not look like a server address."
            }
        }
    }

    /// Parses and normalises a typed base URL.
    ///
    /// - a bare host/port gets `http://` (the LAN service has no TLS);
    /// - scheme is lowercased; only `http` and `https` are accepted;
    /// - query and fragment are dropped (the API has none);
    /// - trailing slashes are removed so `base + "/health"` never doubles up.
    public static func parse(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Invalid.empty }

        if text.range(of: "://") == nil {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text) else {
            throw Invalid.malformed
        }
        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw Invalid.unsupportedScheme(scheme.isEmpty ? "?" : scheme)
        }
        guard let host = components.host, !host.isEmpty else {
            throw Invalid.missingHost
        }
        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        guard let url = components.url else { throw Invalid.malformed }
        return url
    }

    /// Lenient variant for persisted values and text fields.
    public static func normalise(_ raw: String) -> URL? {
        try? parse(raw)
    }

    /// Appends an API path to a base URL without doubling slashes.
    public static func endpoint(_ base: URL, _ path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return base.appendingPathComponent(trimmed)
    }

    /// True for the baked default (Settings shows a "LAN default" note).
    public static func isDefault(_ url: URL) -> Bool {
        url.absoluteString == `default`.absoluteString
    }
}
