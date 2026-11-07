import SwiftUI

/// The only visual decision v0.6 adds (plan T4.12): stock SwiftUI plus one warm
/// accent for primary actions and progress. No design system, no custom
/// components beyond the two product views the mockup asked for.
enum Theme {
    /// #E07B39 — warm terracotta.
    static let accent = Color(red: 224.0 / 255.0,
                              green: 123.0 / 255.0,
                              blue: 57.0 / 255.0)
}
