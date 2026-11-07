import Foundation
import CraftRoomCore

/// Everything the app remembers between launches about the generation backend
/// (plan T3.4): the engine, the server base URL, the developer seed, and the
/// last connection test.
///
/// One JSON blob under one `UserDefaults` key, so a decoded record can never
/// pair a URL from one launch with an engine from another. A decode failure
/// falls back to the first-launch defaults rather than to a half state.
struct EngineSettings: Codable, Equatable {
    var engine: EngineID
    var baseURL: URL
    /// Developer seed (Settings → Developer). nil means "server default / random".
    var seed: UInt64?
    var lastHealth: EngineHealth?

    /// First-launch policy: payload installed -> on-device, otherwise the local
    /// server at the LAN default. Remote mode never needs the payload download.
    static func initial(payloadInstalled: Bool) -> EngineSettings {
        EngineSettings(
            engine: EngineSelection.initialEngine(payloadInstalled: payloadInstalled),
            baseURL: EngineSelection.initialBaseURL(saved: nil),
            seed: nil,
            lastHealth: nil)
    }
}

/// Load/save for `EngineSettings`.
enum EngineSettingsStore {
    static let key = "craftroom.engine.settings.v1"

    static func load(from defaults: UserDefaults = .standard,
                     payloadInstalled: Bool) -> EngineSettings {
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(EngineSettings.self, from: data),
           // A corrupted base URL would be re-validated on the next run; treat
           // anything unparseable as "no saved record".
           ServerURL.normalise(saved.baseURL.absoluteString) != nil {
            return saved
        }
        return .initial(payloadInstalled: payloadInstalled)
    }

    static func save(_ settings: EngineSettings,
                     to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
