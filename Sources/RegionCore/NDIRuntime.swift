import CNDI
import Foundation

public struct RuntimeError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}

/// The dlopen'd NDI library — loaded once per process, shared by all senders.
final class NDIRuntime {
    let path: String
    let sendCreate: NDIlib_send_create_fn
    let sendVideo: NDIlib_send_send_video_v2_fn
    let sendDestroy: NDIlib_send_destroy_fn

    private static var cached: NDIRuntime?

    static func shared() throws -> NDIRuntime {
        if let cached { return cached }
        // Only cache success — a user can install the NDI runtime while we run
        // and a later call should pick it up without relaunching.
        let runtime = try NDIRuntime()
        cached = runtime
        return runtime
    }

    static func runtimeCandidates() -> [String] {
        var paths: [String] = []
        for env in ["NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5"] {
            if let dir = ProcessInfo.processInfo.environment[env] {
                paths.append("\(dir)/libndi.dylib")
            }
        }
        paths += [
            "/usr/local/lib/libndi.dylib",
            "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
            "/Library/Application Support/Resolume/lib/libndi.dylib",
            "/Applications/NDI Video Monitor.app/Contents/Frameworks/libndi_advanced.dylib",
        ]
        return paths
    }

    private init() throws {
        var handle: UnsafeMutableRawPointer?
        var loadedPath = ""
        for path in Self.runtimeCandidates() where FileManager.default.fileExists(atPath: path) {
            if let h = dlopen(path, RTLD_NOW) {
                handle = h
                loadedPath = path
                break
            }
        }
        guard let lib = handle else {
            throw RuntimeError("No NDI runtime found. Install NDI Tools or set NDI_RUNTIME_DIR_V5.")
        }
        path = loadedPath

        func sym<T>(_ name: String, as type: T.Type) throws -> T {
            guard let p = dlsym(lib, name) else {
                throw RuntimeError("Symbol \(name) missing in \(loadedPath)")
            }
            return unsafeBitCast(p, to: T.self)
        }

        let initialize = try sym("NDIlib_initialize", as: NDIlib_initialize_fn.self)
        sendCreate = try sym("NDIlib_send_create", as: NDIlib_send_create_fn.self)
        sendVideo = try sym("NDIlib_send_send_video_v2", as: NDIlib_send_send_video_v2_fn.self)
        sendDestroy = try sym("NDIlib_send_destroy", as: NDIlib_send_destroy_fn.self)

        guard initialize() else {
            throw RuntimeError("NDIlib_initialize failed (unsupported CPU?)")
        }
    }
}

public enum NDIInfo {
    /// Path of the NDI runtime that would be (or was) loaded, nil if none available.
    public static var runtimePath: String? { (try? NDIRuntime.shared())?.path }
}
