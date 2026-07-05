import Foundation
import ScreenCaptureKit

public struct WindowInfo: Identifiable, Hashable {
    public let id: UInt32
    public let app: String
    public let title: String
    public let size: CGSize
    public let scWindow: SCWindow

    public static func == (lhs: WindowInfo, rhs: WindowInfo) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.size == rhs.size
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public var label: String {
        let sizeText = "\(Int(size.width))x\(Int(size.height))"
        return title.isEmpty ? "\(app) (\(sizeText))" : "\(app) — \(title) (\(sizeText))"
    }
}

public enum WindowEnumerator {
    /// Normal app windows big enough to be worth capturing.
    public static func capturableWindows() async throws -> [WindowInfo] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            throw RuntimeError(
                "Cannot enumerate windows (\(error.localizedDescription)). "
                    + "Grant Screen Recording permission in System Settings > Privacy & Security.")
        }
        return content.windows
            // Offscreen windows (phantom duplicates, minimized) never deliver
            // frames, so hide them entirely.
            .filter {
                $0.isOnScreen && $0.windowLayer == 0
                    && $0.frame.width >= 50 && $0.frame.height >= 50
            }
            .map {
                WindowInfo(
                    id: $0.windowID,
                    app: $0.owningApplication?.applicationName ?? "?",
                    title: $0.title ?? "",
                    size: $0.frame.size,
                    scWindow: $0
                )
            }
            .sorted {
                ($0.app.lowercased(), $0.title, $0.id) < ($1.app.lowercased(), $1.title, $1.id)
            }
    }
}
