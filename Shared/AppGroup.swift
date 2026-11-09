import Foundation

/// The shared sandbox that both the main app and the keyboard extension can
/// read and write. This is the backbone of "Option A": the app matches memes
/// and records the user's pick here; the keyboard reads it back.
public enum AppGroup {

    /// Must match the App Groups capability set on *both* targets' entitlements.
    public static let identifier = "group.com.leventemurgas.MemeMatcher"

    /// Shared small settings — the app→keyboard hand-off channel.
    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// Shared folder on disk. Not needed yet: memes are bundled in the app, so
    /// only the *filename* crosses the boundary, not image bytes.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Quick diagnostic: is the App Group container actually reachable?
    /// If this is nil, the entitlement/capability is misconfigured.
    public static var isContainerAvailable: Bool {
        containerURL != nil
    }

    // MARK: - Selected meme (M4)

    /// What the user picked in the app, for the keyboard to confirm.
    public struct Selection {
        public let file: String
        public let date: Date
    }

    private static let selectedFileKey = "selection.file"
    private static let selectedDateKey = "selection.date"
    private static let thumbnailFileName = "selection-thumb.png"

    /// Record the meme the user just chose (and copied to the pasteboard).
    ///
    /// The thumbnail matters: the keyboard extension's `Bundle.main` is the
    /// *extension's* bundle, which doesn't contain the meme images — so the
    /// only way it can show what was copied is through the shared container.
    /// Deliberately a small downscaled PNG, since keyboards run under a tight
    /// memory budget.
    public static func writeSelection(file: String, thumbnailPNG: Data?) {
        defaults?.set(file, forKey: selectedFileKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: selectedDateKey)
        guard let url = thumbnailURL else { return }
        if let thumbnailPNG {
            try? thumbnailPNG.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static var thumbnailURL: URL? {
        containerURL?.appendingPathComponent(thumbnailFileName)
    }

    /// PNG data for the last copied meme, readable from both targets.
    public static func readSelectionThumbnail() -> Data? {
        guard let url = thumbnailURL else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Keyboard status (M5)

    /// What the keyboard reports about itself, so the app's tutorial can show
    /// live setup progress.
    ///
    /// There is no API for the *app* to ask "is my keyboard enabled?" or "does
    /// it have Full Access?" — but the keyboard knows both, and App Group
    /// writes work even *without* Full Access. So the keyboard writes its own
    /// status here whenever it loads, and the app reads it back. The trade-off:
    /// this only becomes known once the keyboard has been shown at least once.
    public struct KeyboardStatus {
        public let hasFullAccess: Bool
        public let lastSeen: Date
    }

    private static let fullAccessKey = "keyboard.hasFullAccess"
    private static let keyboardSeenKey = "keyboard.lastSeen"

    public static func writeKeyboardStatus(hasFullAccess: Bool) {
        defaults?.set(hasFullAccess, forKey: fullAccessKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: keyboardSeenKey)
    }

    public static func readKeyboardStatus() -> KeyboardStatus? {
        guard let seen = defaults?.double(forKey: keyboardSeenKey), seen > 0 else { return nil }
        return KeyboardStatus(hasFullAccess: defaults?.bool(forKey: fullAccessKey) ?? false,
                              lastSeen: Date(timeIntervalSince1970: seen))
    }

    /// The most recent pick, or nil if the user hasn't chosen one yet.
    public static func readSelection() -> Selection? {
        guard let file = defaults?.string(forKey: selectedFileKey),
              let timestamp = defaults?.double(forKey: selectedDateKey), timestamp > 0
        else { return nil }
        return Selection(file: file, date: Date(timeIntervalSince1970: timestamp))
    }
}
