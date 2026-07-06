import AppKit
import Foundation
import RegionCore
import SwiftUI
import UniformTypeIdentifiers

enum FeedStatus: Equatable {
    case stopped
    case starting
    case running(String)
    /// Sender still on air (showing the slate), watching for the window to come back.
    case waiting(String)
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
    @Published private(set) var userPresets: [FeedPreset] = []
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

    private struct Waiting {
        let sender: NDISender
        let watch: Task<Void, Never>
    }

    private var running: [UUID: Running] = [:]
    private var waiting: [UUID: Waiting] = [:]
    /// Last live output size per feed, so the slate matches and receivers
    /// don't see a resolution change.
    private var lastPixelSize: [UUID: (w: Int, h: Int)] = [:]
    private var isLoading = false

    private var supportDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("CaptureNDIRegion", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var configURL: URL { supportDir.appendingPathComponent("feeds.json") }
    private var presetsURL: URL { supportDir.appendingPathComponent("presets.json") }
    /// Extension-less on purpose: NSImage(data:) sniffs the format, so any
    /// image type the user picks just works.
    private var slateImageURL: URL { supportDir.appendingPathComponent("slate-image") }

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
        }
        // First launch: no feeds — the empty state offers presets instead of
        // silently assuming everyone wants the author's ShowKontrol setup.
        if let presetData = try? Data(contentsOf: presetsURL),
           let saved = try? JSONDecoder().decode([FeedPreset].self, from: presetData) {
            userPresets = saved
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
        feeds.append(Feed(name: "Region \(feeds.count + 1)", appQuery: ""))
    }

    // MARK: - Presets

    /// Built-ins plus the user's own; a user preset with the same name as a
    /// built-in shadows it.
    var allPresets: [FeedPreset] {
        let userNames = Set(userPresets.map(\.name))
        return FeedPreset.builtIns.filter { !userNames.contains($0.name) } + userPresets
    }

    func addFeed(from preset: FeedPreset) {
        var feed = preset.feed
        feed.id = UUID()  // presets keep their template's id; feeds need fresh ones
        feed.selectedWindowID = nil
        feeds.append(feed)
    }

    /// The preset takes the feed's NDI name; saving again under the same name
    /// overwrites.
    func savePreset(from feed: Feed) {
        var template = feed
        template.selectedWindowID = nil
        userPresets.removeAll { $0.name == feed.name }
        userPresets.append(FeedPreset(name: feed.name, feed: template))
        userPresets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        savePresets()
        footerNote = "Saved preset \"\(feed.name)\""
    }

    func deletePreset(id: UUID) {
        guard let preset = userPresets.first(where: { $0.id == id }) else { return }
        userPresets.removeAll { $0.id == id }
        savePresets()
        footerNote = "Deleted preset \"\(preset.name)\""
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(userPresets) {
            try? data.write(to: presetsURL, options: .atomic)
        }
    }

    // MARK: - Slate image

    var hasCustomSlateImage: Bool {
        FileManager.default.fileExists(atPath: slateImageURL.path)
    }

    func chooseSlateImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the image shown on the NDI output while a feed waits for its window"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
        try? data.write(to: slateImageURL, options: .atomic)
        footerNote = "Slate image set — used next time a feed loses its window"
    }

    func resetSlateImage() {
        try? FileManager.default.removeItem(at: slateImageURL)
        footerNote = "Slate image reset to the studio dawg"
    }

    /// Custom image if one is set, otherwise the bundled dawg.
    private func slateImage() -> NSImage? {
        if let data = try? Data(contentsOf: slateImageURL), let image = NSImage(data: data) {
            return image
        }
        if let path = Bundle.main.path(forResource: "DAWG", ofType: "png") {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }

    func removeFeed(id: UUID) async {
        await stop(id: id)
        feeds.removeAll { $0.id == id }
        statuses[id] = nil
        lastPixelSize[id] = nil
    }

    func start(id: UUID) async {
        guard running[id] == nil, waiting[id] == nil,
              let index = feeds.firstIndex(where: { $0.id == id }) else { return }
        statuses[id] = .starting
        // Always re-enumerate: window ids from an earlier scan may be dead
        // (restarting a feed against a stale list is how feeds got stuck).
        await refreshWindows()

        let feed = feeds[index]
        guard feed.selectedWindowID != nil || !feed.appQuery.isEmpty || !feed.titleQuery.isEmpty
        else {
            statuses[id] = .error("Pick a window or type an app name to match")
            return
        }
        do {
            let sender = try NDISender(name: feed.name)
            if let window = resolveWindow(for: feed, in: windows) {
                feeds[index].selectedWindowID = window.id
                do {
                    try await beginCapture(id: id, window: window, sender: sender)
                } catch {
                    // Don't leave a ghost NDI source on the network.
                    sender.shutdown()
                    statuses[id] = .error("\(error)")
                }
            } else {
                // Go on air anyway: slate until the window shows up.
                enterWaiting(id: id, sender: sender, title: "Waiting for window")
            }
        } catch {
            statuses[id] = .error("\(error)")
        }
    }

    /// Wire up and start a capture on an existing (possibly reused) sender.
    private func beginCapture(id: UUID, window: WindowInfo, sender: NDISender) async throws {
        guard let feed = feeds.first(where: { $0.id == id }) else {
            sender.shutdown()
            return
        }
        let capture = RegionCapture(window: window.scWindow, sender: sender, spec: feed.regionSpec)
        capture.onStatus = { [weak self] w, h in
            Task { @MainActor in
                self?.lastPixelSize[id] = (w, h)
                self?.statuses[id] = .running("\(w)×\(h)")
            }
        }
        capture.onStop = { [weak self] error in
            Task { @MainActor in
                // Manual stop already cleaned up; only unexpected stops land here.
                guard let self, let r = self.running.removeValue(forKey: id) else { return }
                r.poll.cancel()
                if error != nil {
                    self.enterWaiting(id: id, sender: r.sender)
                } else {
                    r.sender.shutdown()
                    self.statuses[id] = .stopped
                }
            }
        }
        capture.onSourceLost = { [weak self] in
            Task { @MainActor in
                guard let self, let r = self.running.removeValue(forKey: id) else { return }
                r.poll.cancel()
                await r.capture.stop()
                self.enterWaiting(id: id, sender: r.sender)
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
    }

    /// The window is gone (or was never there): keep the NDI source alive with
    /// the slate and watch for a window matching the feed's queries; reattach
    /// automatically when one appears.
    private func enterWaiting(id: UUID, sender: NDISender, title: String = "Window went away") {
        guard waiting[id] == nil else {
            sender.shutdown()
            return
        }
        guard let feed = feeds.first(where: { $0.id == id }) else {
            sender.shutdown()
            return
        }
        let target = feed.titleQuery.isEmpty
            ? feed.appQuery : "\(feed.appQuery) — \(feed.titleQuery)"
        statuses[id] = .waiting("\(title) — watching for \"\(target)\"")
        let size = lastPixelSize[id] ?? (w: 1280, h: 720)
        let slate = SlateRenderer.render(
            width: size.w, height: size.h,
            title: title,
            subtitle: "Watching for \(target) — reconnects automatically",
            image: slateImage())
        let fps = Int32(feed.fps)

        let watch = Task { [weak self] in
            while !Task.isCancelled {
                slate.send(via: sender, fps: fps)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard let feed = self.feeds.first(where: { $0.id == id }) else { return }
                let fresh = (try? await WindowEnumerator.capturableWindows()) ?? []
                if let window = self.resolveWindow(for: feed, in: fresh) {
                    self.reattach(id: id, window: window, sender: sender)
                    return
                }
            }
        }
        waiting[id] = Waiting(sender: sender, watch: watch)
    }

    private func reattach(id: UUID, window: WindowInfo, sender: NDISender) {
        waiting[id] = nil  // the watch task returns right after calling us
        if let index = feeds.firstIndex(where: { $0.id == id }) {
            feeds[index].selectedWindowID = window.id
        }
        statuses[id] = .starting
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.beginCapture(id: id, window: window, sender: sender)
            } catch {
                // Matched but couldn't attach (window died again mid-start) —
                // back to watching.
                self.enterWaiting(id: id, sender: sender)
            }
        }
    }

    func stop(id: UUID) async {
        if let w = waiting.removeValue(forKey: id) {
            w.watch.cancel()
            w.sender.shutdown()
            statuses[id] = .stopped
            return
        }
        guard let r = running.removeValue(forKey: id) else { return }
        r.poll.cancel()
        await r.capture.stop()
        r.sender.shutdown()
        statuses[id] = .stopped
    }

    /// Explicit picker choice wins; otherwise best match for the saved queries.
    /// Matching is against a caller-supplied list so the reattach watcher can
    /// use a fresh enumeration without churning the published `windows`.
    private func resolveWindow(for feed: Feed, in list: [WindowInfo]) -> WindowInfo? {
        if let sel = feed.selectedWindowID, let w = list.first(where: { $0.id == sel }) {
            return w
        }
        guard !feed.appQuery.isEmpty || !feed.titleQuery.isEmpty else { return nil }
        // Empty app query with a title query means "any app".
        let candidates = list
            .filter { feed.appQuery.isEmpty || queryMatches($0.app, feed.appQuery) }
            .sorted { $0.size.width * $0.size.height > $1.size.width * $1.size.height }
        if !feed.titleQuery.isEmpty {
            if let exact = candidates.first(where: { $0.title == feed.titleQuery }) { return exact }
            if let partial = candidates.first(where: {
                queryMatches($0.title, feed.titleQuery)
            }) { return partial }
        }
        // Title-only feeds must match on title; never fall back to "any window".
        return feed.appQuery.isEmpty ? nil : candidates.first
    }

    /// Case-insensitive substring by default; a query containing * or ?
    /// is treated as a glob matched against the whole string
    /// (e.g. "Show*" or "*Kontrol*").
    private func queryMatches(_ text: String, _ query: String) -> Bool {
        guard !query.isEmpty else { return false }
        if query.contains("*") || query.contains("?") {
            return NSPredicate(format: "SELF LIKE[cd] %@", query).evaluate(with: text)
        }
        return text.localizedCaseInsensitiveContains(query)
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
