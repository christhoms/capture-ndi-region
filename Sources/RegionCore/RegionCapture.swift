import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

public struct RegionSpec {
    public enum Crop {
        /// A strip anchored to the bottom edge, this many window points tall.
        case bottomStrip(CGFloat)
        /// An arbitrary rect in window points, origin at the window's top-left.
        case rect(CGRect)
    }

    public var crop: Crop
    /// Output width cap in pixels; height follows the aspect ratio.
    public var maxWidth: Int
    public var fps: Int32
    public var showsCursor: Bool

    public init(crop: Crop, maxWidth: Int, fps: Int32, showsCursor: Bool = false) {
        self.crop = crop
        self.maxWidth = maxWidth
        self.fps = fps
        self.showsCursor = showsCursor
    }
}

public final class RegionCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sender: NDISender
    private let spec: RegionSpec
    private let windowID: CGWindowID
    private var stream: SCStream?
    private var lastWindowSize: CGSize = .zero
    private var missCount = 0
    private var frameCount = 0
    private let frameQueue = DispatchQueue(label: "ndi-region.frames")

    /// Called when the stream stops (nil error = clean stop requested by us).
    public var onStop: ((Error?) -> Void)?
    /// Called once when the target window disappears from enumeration
    /// (two consecutive misses, so a single flaky enumeration doesn't trigger it).
    public var onSourceLost: (() -> Void)?
    /// Called with the output pixel size when capture starts or reconfigures.
    public var onStatus: ((Int, Int) -> Void)?
    /// Human-readable progress messages.
    public var onLog: ((String) -> Void)?
    /// If set, the first captured frame is also written here as a PNG.
    public var dumpFirstFrameURL: URL?

    public init(window: SCWindow, sender: NDISender, spec: RegionSpec) {
        self.sender = sender
        self.spec = spec
        self.windowID = window.windowID
        super.init()
    }

    private func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let content = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)

        let source: CGRect
        switch spec.crop {
        case .bottomStrip(let height):
            let cropHeight = min(height, content.height)
            source = CGRect(
                x: 0, y: content.height - cropHeight,
                width: content.width, height: cropHeight
            )
        case .rect(let rect):
            // Clamp to the window's content bounds.
            let x = min(max(0, rect.minX), max(0, content.width - 2))
            let y = min(max(0, rect.minY), max(0, content.height - 2))
            source = CGRect(
                x: x, y: y,
                width: max(2, min(rect.width, content.width - x)),
                height: max(2, min(rect.height, content.height - y))
            )
        }

        // Native pixel size of the crop, then scale down to fit maxWidth.
        let nativeW = source.width * scale
        let nativeH = source.height * scale
        var outW = min(CGFloat(spec.maxWidth), nativeW)
        var outH = (outW / nativeW) * nativeH
        // Even dimensions keep NDI receivers and downstream encoders happy.
        outW = (outW / 2).rounded(.down) * 2
        outH = max(2, (outH / 2).rounded(.down) * 2)

        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = Int(outW)
        config.height = Int(outH)
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = spec.showsCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: spec.fps)
        config.queueDepth = 5
        return config
    }

    public func start(window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = configuration(for: filter)
        lastWindowSize = filter.contentRect.size

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try await stream.startCapture()
        self.stream = stream

        onLog?(
            "Capturing window \(windowID): \(cropDescription()) of \(Int(lastWindowSize.width))x\(Int(lastWindowSize.height))pt -> \(config.width)x\(config.height)px @ \(spec.fps)fps"
        )
        onStatus?(config.width, config.height)
    }

    private func cropDescription() -> String {
        switch spec.crop {
        case .bottomStrip(let h): return "bottom \(Int(h))pt"
        case .rect(let r):
            return "rect \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))pt"
        }
    }

    /// Re-check the window size and update crop/scale if it changed.
    public func refreshIfResized() async {
        guard let stream else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                missCount += 1
                if missCount == 2 { onSourceLost?() }
                return
            }
            missCount = 0
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = filter.contentRect.size
            guard size != lastWindowSize else { return }
            lastWindowSize = size
            let config = configuration(for: filter)
            try await stream.updateContentFilter(filter)
            try await stream.updateConfiguration(config)
            onLog?(
                "Window resized to \(Int(size.width))x\(Int(size.height))pt -> output \(config.width)x\(config.height)px"
            )
            onStatus?(config.width, config.height)
        } catch {
            onLog?("Resize refresh failed: \(error)")
        }
    }

    public func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: - SCStreamOutput

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            statusRaw == SCFrameStatus.complete.rawValue,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        sender.send(
            pixels: base,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            fpsN: spec.fps, fpsD: 1
        )
        frameCount += 1
        if frameCount == 1 {
            onLog?("First frame sent.")
            if let url = dumpFirstFrameURL {
                dumpFrame(pixelBuffer, to: url)
            }
        }
    }

    private func dumpFrame(_ pixelBuffer: CVPixelBuffer, to url: URL) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        do {
            try context.writePNGRepresentation(
                of: image, to: url, format: .BGRA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            onLog?("Wrote first frame to \(url.path)")
        } catch {
            onLog?("Frame dump failed: \(error)")
        }
    }

    // MARK: - SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
