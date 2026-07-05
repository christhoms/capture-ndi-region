import Foundation
import RegionCore
import ScreenCaptureKit

let usage = """
ndi-region — send a cropped, scaled region of a macOS window as an NDI source

USAGE:
  ndi-region --list
  ndi-region --app <name> [--title <substring>] [options]
  ndi-region --window-id <id> [options]

WINDOW SELECTION:
  --list              List capturable windows (app, title, id, size) and exit
  --app <name>        Match by application name (case-insensitive substring)
  --title <substr>    Additionally match by window title
  --window-id <id>    Capture an exact window id from --list

OPTIONS:
  --bottom <pt>       Height of bottom strip to capture, in window points (default 400)
  --rect <x,y,w,h>    Capture an arbitrary rect in window points, origin top-left
                      (overrides --bottom)
  --max-width <px>    Maximum output width in pixels, aspect preserved (default 1920)
  --fps <n>           Frame rate cap (default 30)
  --name <ndi name>   NDI source name (default "Region - <app>")
  --cursor            Include the mouse cursor (default off)
  --dump-frame <path> Also write the first captured frame to a PNG (debugging)

Requires Screen Recording permission for the terminal running it
(System Settings > Privacy & Security > Screen Recording).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
}

struct Options {
    var list = false
    var app: String?
    var title: String?
    var windowID: CGWindowID?
    var bottom: CGFloat = 400
    var rect: CGRect?
    var maxWidth = 1920
    var fps: Int32 = 30
    var name: String?
    var cursor = false
    var dumpFrame: String?
}

func parseOptions() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    func value(for flag: String) -> String {
        guard !args.isEmpty else { fail("\(flag) requires a value") }
        return args.removeFirst()
    }

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--list": opts.list = true
        case "--app": opts.app = value(for: arg)
        case "--title": opts.title = value(for: arg)
        case "--window-id":
            guard let id = UInt32(value(for: arg)) else { fail("--window-id must be a number") }
            opts.windowID = id
        case "--bottom":
            guard let v = Double(value(for: arg)), v > 0 else { fail("--bottom must be > 0") }
            opts.bottom = v
        case "--rect":
            let parts = value(for: arg).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, parts[2] > 0, parts[3] > 0 else {
                fail("--rect must be x,y,w,h with positive w,h")
            }
            opts.rect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        case "--max-width":
            guard let v = Int(value(for: arg)), v > 0 else { fail("--max-width must be > 0") }
            opts.maxWidth = v
        case "--fps":
            guard let v = Int32(value(for: arg)), v > 0, v <= 120 else { fail("--fps must be 1-120") }
            opts.fps = v
        case "--name": opts.name = value(for: arg)
        case "--cursor": opts.cursor = true
        case "--dump-frame": opts.dumpFrame = value(for: arg)
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            fail("unknown argument \(arg)\n\n\(usage)")
        }
    }
    return opts
}

func listWindows(_ windows: [WindowInfo]) {
    print("ID".padding(toLength: 10, withPad: " ", startingAt: 0)
        + "APP".padding(toLength: 28, withPad: " ", startingAt: 0)
        + "SIZE".padding(toLength: 12, withPad: " ", startingAt: 0)
        + "TITLE")
    for w in windows {
        let size = "\(Int(w.size.width))x\(Int(w.size.height))"
        print("\(w.id)".padding(toLength: 10, withPad: " ", startingAt: 0)
            + w.app.prefix(27).padding(toLength: 28, withPad: " ", startingAt: 0)
            + size.padding(toLength: 12, withPad: " ", startingAt: 0)
            + w.title)
    }
}

func selectWindow(_ windows: [WindowInfo], opts: Options) throws -> WindowInfo {
    if let id = opts.windowID {
        guard let w = windows.first(where: { $0.id == id }) else {
            throw RuntimeError("No window with id \(id). Use --list to see windows.")
        }
        return w
    }
    guard let appQuery = opts.app else {
        throw RuntimeError("Specify --app, --window-id, or --list.\n\n\(usage)")
    }
    let matches = windows.filter { w in
        guard w.app.localizedCaseInsensitiveContains(appQuery) else { return false }
        if let titleQuery = opts.title {
            return w.title.localizedCaseInsensitiveContains(titleQuery)
        }
        return true
    }
    guard let window = matches.max(by: {
        $0.size.width * $0.size.height < $1.size.width * $1.size.height
    }) else {
        throw RuntimeError("No window matching --app \"\(appQuery)\""
            + (opts.title.map { " --title \"\($0)\"" } ?? "") + ". Use --list to see windows.")
    }
    if matches.count > 1 {
        log("Note: \(matches.count) windows matched; using the largest (id \(window.id), \"\(window.title)\"). Use --window-id to pin one.")
    }
    return window
}

// MARK: - Entry point

// Initialize the window-server connection on the main thread; without this,
// SCContentFilter asserts (CGS_REQUIRE_INIT) when used from a Task thread.
_ = CGMainDisplayID()

let opts = parseOptions()

let task = Task {
    do {
        let windows = try await WindowEnumerator.capturableWindows()
        if opts.list {
            listWindows(windows)
            exit(0)
        }
        let window = try selectWindow(windows, opts: opts)
        let sender = try NDISender(name: opts.name ?? "Region - \(window.app)")
        log("NDI runtime: \(sender.runtimePath)")
        let crop: RegionSpec.Crop = opts.rect.map { .rect($0) } ?? .bottomStrip(opts.bottom)
        let spec = RegionSpec(
            crop: crop, maxWidth: opts.maxWidth, fps: opts.fps, showsCursor: opts.cursor)
        let capture = RegionCapture(window: window.scWindow, sender: sender, spec: spec)
        capture.onLog = { log($0) }
        capture.dumpFirstFrameURL = opts.dumpFrame.map { URL(fileURLWithPath: $0) }
        capture.onStop = { error in
            if let error { log("Stream stopped: \(error)") }
            sender.shutdown()
            exit(error == nil ? 0 : 1)
        }
        try await capture.start(window: window.scWindow)

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            Task {
                await capture.stop()
                sender.shutdown()
                exit(0)
            }
        }
        sigint.resume()

        // Poll for window resizes so the crop stays glued to the target region.
        while true {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            await capture.refreshIfResized()
        }
    } catch {
        fail("\(error)")
    }
}
_ = task
dispatchMain()
