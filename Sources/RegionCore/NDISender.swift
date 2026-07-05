import CNDI
import Foundation

/// One NDI source. Multiple senders can coexist in a process.
public final class NDISender {
    private let runtime: NDIRuntime
    private var instance: UnsafeMutableRawPointer?
    private let lock = NSLock()

    /// 'BGRA' in NDI's little-endian FourCC encoding.
    private static let fourCCBGRA: UInt32 = 0x4152_4742

    public var runtimePath: String { runtime.path }

    public init(name: String) throws {
        runtime = try NDIRuntime.shared()
        var inst: UnsafeMutableRawPointer?
        name.withCString { cName in
            var desc = NDIlib_send_create_t(
                p_ndi_name: cName, p_groups: nil, clock_video: false, clock_audio: false
            )
            inst = withUnsafePointer(to: &desc) { runtime.sendCreate($0) }
        }
        guard let created = inst else {
            throw RuntimeError("NDIlib_send_create failed")
        }
        instance = created
    }

    public func send(pixels: UnsafeMutableRawPointer, width: Int, height: Int,
                     bytesPerRow: Int, fpsN: Int32, fpsD: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard let instance else { return }
        var frame = NDIlib_video_frame_v2_t(
            xres: Int32(width),
            yres: Int32(height),
            FourCC: Self.fourCCBGRA,
            frame_rate_N: fpsN,
            frame_rate_D: fpsD,
            picture_aspect_ratio: Float(width) / Float(height),
            frame_format_type: CNDI_FRAME_FORMAT_PROGRESSIVE,
            timecode: Int64.max,
            p_data: pixels.assumingMemoryBound(to: UInt8.self),
            line_stride_in_bytes: Int32(bytesPerRow),
            p_metadata: nil,
            timestamp: 0
        )
        withUnsafePointer(to: &frame) { runtime.sendVideo(instance, $0) }
    }

    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        if let instance {
            runtime.sendDestroy(instance)
            self.instance = nil
        }
    }
}
