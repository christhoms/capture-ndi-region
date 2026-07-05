import Foundation
import RegionCore

enum CropMode: String, Codable, CaseIterable, Identifiable {
    case bottom
    case rect
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottom: return "Bottom strip"
        case .rect: return "Custom rect"
        }
    }
}

struct Feed: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var appQuery: String
    var titleQuery: String = ""
    var cropMode: CropMode = .bottom
    var bottom: Double = 220
    var rectX: Double = 0
    var rectY: Double = 0
    var rectW: Double = 640
    var rectH: Double = 220
    var maxWidth: Int = 1920
    var fps: Int = 30
    var autoStart: Bool = false

    /// Session-only; window ids are not stable across reboots.
    var selectedWindowID: UInt32? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, appQuery, titleQuery, cropMode, bottom
        case rectX, rectY, rectW, rectH, maxWidth, fps, autoStart
    }

    var regionSpec: RegionSpec {
        let crop: RegionSpec.Crop
        switch cropMode {
        case .bottom: crop = .bottomStrip(bottom)
        case .rect: crop = .rect(CGRect(x: rectX, y: rectY, width: rectW, height: rectH))
        }
        return RegionSpec(crop: crop, maxWidth: maxWidth, fps: Int32(fps), showsCursor: false)
    }
}
