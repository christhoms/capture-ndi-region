import Foundation

/// A reusable feed configuration. Loading one adds a feed row; the preset
/// keeps no link to the feed afterwards.
struct FeedPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var feed: Feed

    /// Presets shipped with the app. Add more here as they prove useful.
    static let builtIns: [FeedPreset] = [
        FeedPreset(
            name: "ShowKontrol Decks",
            feed: Feed(name: "SK Decks Only", appQuery: "ShowKontrol")
        )
    ]
}
