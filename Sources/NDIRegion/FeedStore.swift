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
final class FeedStore: ObservableObject {
    @Published var feeds: [Feed] = [] {
        didSet { if !isLoading { save() } }
    }
    @Published var windows: [WindowInfo] = []
    @Published var footerNote: String = ""
    @Published private(set) var statuses: [UUID: FeedStatus] = [:]
    @Published private(set) var permission: ScreenPermission = .granted

    private var permissionPoll: Task<Void, Never>?

    private struct Running {
        let capture: RegionCapture
        let sender: NDISender
        let poll: Task<Void, Never>
    }

    private var running: [UUID: Running] = [:]
    private var isLoading = false

    private var configURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NDIRegion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feeds.json")
    }

    init() {
        isLoading = true
        if let data = try? Data(contentsOf: configURL),
           let saved = try? JSONDecoder().decode([Feed].self, from: data), !saved.isEmpty {
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
        let ndiPath = NDIInfo.runtimePath
        footerNote = ndiPath.map { "NDI runtime: \($0)" }
            ?? "No NDI runtime found — install NDI Tools"
        guard permission == .granted else { return }
        for feed in feeds where feed.autoStart {
            await start(id: feed.id)
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
        let bundleID = Bundle.main.bundleIdentifier ?? "uk.co.christhoms.ndiregion"
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
        // Offscreen windows usually never deliver frames, so prefer on-screen ones.
        let candidates = windows
            .filter { $0.app.localizedCaseInsensitiveContains(feed.appQuery) }
            .sorted {
                ($0.isOnScreen ? 0 : 1, -$0.size.width * $0.size.height)
                    < ($1.isOnScreen ? 0 : 1, -$1.size.width * $1.size.height)
            }
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
