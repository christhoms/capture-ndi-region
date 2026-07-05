import AppKit
import Foundation
import RegionCore
import SwiftUI

enum FeedStatus: Equatable {
    case stopped
    case starting
    case running(String)
    case error(String)
}

enum ScreenPermission: Equatable {
    case granted
    case denied
    /// Granted while running — capture only works after a relaunch.
    case grantedNeedsRelaunch
}

@MainActor
final class FeedStore: NSObject, ObservableObject {
    @Published var feeds: [Feed] = [] {
        didSet { if !isLoading { save() } }
    }
    @Published var windows: [WindowInfo] = []
    @Published var footerNote: String = ""
    @Published private(set) var statuses: [UUID: FeedStatus] = [:]
    @Published private(set) var permission: ScreenPermission = .granted
    @Published private(set) var ndiRuntimeMissing = false
    /// Show-mode: window shrunk to a slim titlebar strip.
    @Published var collapsed = false

    private var permissionPoll: Task<Void, Never>?
    private weak var window: NSWindow?

    private struct Running {
        let capture: RegionCapture
        let sender: NDISender
        let poll: Task<Void, Never>
    }

    private var running: [UUID: Running] = [:]
    private var isLoading = false

    private var configURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("CaptureNDIRegion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feeds.json")
    }

    /// Pre-rename config location, read once as a migration fallback.
    private var legacyConfigURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NDIRegion/feeds.json")
    }

    override init() {
        super.init()
        collapsed = ProcessInfo.processInfo.environment["CNR_START_COLLAPSED"] == "1"
        isLoading = true
        let data = (try? Data(contentsOf: configURL)) ?? (try? Data(contentsOf: legacyConfigURL))
        if let data, let saved = try? JSONDecoder().decode([Feed].self, from: data),
           !saved.isEmpty {
            feeds = saved
        } else {
            feeds = [Feed(name: "SK Decks Only", appQuery: "ShowKontrol")]
        }
        isLoading = false
    }

    private func save() {
        if let data = try? JSONEncoder().encode(feeds) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    var liveFeedCount: Int {
        statuses.values.reduce(0) { count, status in
            if case .running = status { return count + 1 }
            return count
        }
    }

    // MARK: - Window behaviour (no fullscreen, close = collapse)

    func configure(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // A utility window — fullscreen makes no sense for it.
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        // Close collapses to the titlebar strip; close again (or Cmd-W/Cmd-Q) quits.
        if let close = window.standardWindowButton(.closeButton) {
            close.target = self
            close.action = #selector(closeButtonClicked)
        }
    }

    @objc private func closeButtonClicked() {
        if collapsed {
            NSApp.terminate(nil)
        } else {
            collapsed = true
        }
    }

    func status(_ id: UUID) -> FeedStatus { statuses[id] ?? .stopped }
    func isRunning(_ id: UUID) -> Bool {
        if case .stopped = status(id) { return false }
        if case .error = status(id) { return false }
        return true
    }

    func onLaunch() async {
        if CGPreflightScreenCaptureAccess() {
            permission = .granted
        } else {
            permission = .denied
            // Shows the system prompt if undetermined; silently no-op after a denial
            // (the banner's Request Again handles that case).
            CGRequestScreenCaptureAccess()
            startPermissionPolling()
        }
        await refreshWindows()
        recheckNDIRuntime()
        guard permission == .granted else { return }
        for feed in feeds where feed.autoStart {
            await start(id: feed.id)
        }
        // Show-mode: auto-started feeds are live and nothing needs attention,
        // so get out of the way.
        if liveFeedCount > 0 && !ndiRuntimeMissing {
            collapsed = true
        }
    }

    // MARK: - NDI runtime discovery

    /// dlopen retries on every call until it succeeds, so installing the NDI
    /// runtime while we run just needs a re-check, not a relaunch.
    func recheckNDIRuntime() {
        let path = NDIInfo.runtimePath
        ndiRuntimeMissing = path == nil
        footerNote = path.map { "NDI runtime: \($0)" } ?? "No NDI runtime found"
    }

    func openNDIDownload() {
        // NDI's official runtime-only redistributable for macOS.
        if let url = URL(string: "https://ndi.link/NDIRedistV6Apple") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Screen Recording permission recovery

    /// Watch for the grant landing in System Settings while we run.
    private func startPermissionPolling() {
        permissionPoll?.cancel()
        permissionPoll = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if CGPreflightScreenCaptureAccess() {
                    permission = .grantedNeedsRelaunch
                    return
                }
            }
        }
    }

    /// After an accidental Deny, macOS never re-prompts by itself. Resetting our
    /// own TCC entry makes the permission undetermined again, so the system
    /// prompt genuinely reappears.
    func requestPermissionAgain() {
        let bundleID = Bundle.main.bundleIdentifier ?? "uk.co.christhoms.capturendiregion"
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "ScreenCapture", bundleID]
        try? reset.run()
        reset.waitUntilExit()
        CGRequestScreenCaptureAccess()
        startPermissionPolling()
    }

    func openScreenRecordingSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Screen-capture grants only take effect at process launch.
    func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            let opener = Process()
            opener.executableURL = URL(fileURLWithPath: "/bin/sh")
            opener.arguments = ["-c", "sleep 0.4; /usr/bin/open -n \"\(bundlePath)\""]
            try? opener.run()
        }
        NSApp.terminate(nil)
    }

    func refreshWindows() async {
        do {
            windows = try await WindowEnumerator.capturableWindows()
            // Drop selections whose window no longer exists.
            for i in feeds.indices {
                if let sel = feeds[i].selectedWindowID, !windows.contains(where: { $0.id == sel }) {
                    feeds[i].selectedWindowID = nil
                }
            }
        } catch {
            footerNote = "\(error)"
        }
    }

    func addFeed() {
        feeds.append(Feed(name: "Region \(feeds.count + 1)", appQuery: "ShowKontrol"))
    }

    func removeFeed(id: UUID) async {
        await stop(id: id)
        feeds.removeAll { $0.id == id }
        statuses[id] = nil
    }

    func start(id: UUID) async {
        guard running[id] == nil, let index = feeds.firstIndex(where: { $0.id == id }) else { return }
        statuses[id] = .starting
        if windows.isEmpty { await refreshWindows() }

        let feed = feeds[index]
        guard let window = resolveWindow(for: feed) else {
            statuses[id] = .error("No window matching \"\(feed.appQuery)\"")
            return
        }
        feeds[index].selectedWindowID = window.id

        do {
            let sender = try NDISender(name: feed.name)
            let capture = RegionCapture(window: window.scWindow, sender: sender, spec: feed.regionSpec)
            capture.onStatus = { [weak self] w, h in
                Task { @MainActor in self?.statuses[id] = .running("\(w)×\(h)") }
            }
            capture.onStop = { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let r = self.running.removeValue(forKey: id) {
                        r.poll.cancel()
                        r.sender.shutdown()
                    }
                    self.statuses[id] = error.map { .error($0.localizedDescription) } ?? .stopped
                }
            }
            try await capture.start(window: window.scWindow)
            let poll = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await capture.refreshIfResized()
                }
            }
            running[id] = Running(capture: capture, sender: sender, poll: poll)
        } catch {
            statuses[id] = .error("\(error)")
        }
    }

    func stop(id: UUID) async {
        guard let r = running.removeValue(forKey: id) else { return }
        r.poll.cancel()
        await r.capture.stop()
        r.sender.shutdown()
        statuses[id] = .stopped
    }

    /// Explicit picker choice wins; otherwise best match for the saved queries.
    private func resolveWindow(for feed: Feed) -> WindowInfo? {
        if let sel = feed.selectedWindowID, let w = windows.first(where: { $0.id == sel }) {
            return w
        }
        let candidates = windows
            .filter { $0.app.localizedCaseInsensitiveContains(feed.appQuery) }
            .sorted { $0.size.width * $0.size.height > $1.size.width * $1.size.height }
        if !feed.titleQuery.isEmpty {
            if let exact = candidates.first(where: { $0.title == feed.titleQuery }) { return exact }
            if let partial = candidates.first(where: {
                $0.title.localizedCaseInsensitiveContains(feed.titleQuery)
            }) { return partial }
        }
        return candidates.first
    }

    /// Keep saved queries in sync when the user picks a window explicitly.
    func noteSelection(feedID: UUID, windowID: UInt32?) {
        guard let index = feeds.firstIndex(where: { $0.id == feedID }) else { return }
        feeds[index].selectedWindowID = windowID
        if let windowID, let w = windows.first(where: { $0.id == windowID }) {
            feeds[index].appQuery = w.app
            feeds[index].titleQuery = w.title
        }
    }
}
