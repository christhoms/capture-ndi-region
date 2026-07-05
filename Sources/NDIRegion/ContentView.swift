import RegionCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: FeedStore

    var body: some View {
        VStack(spacing: 0) {
            if store.permission != .granted {
                permissionBanner
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($store.feeds) { $feed in
                        FeedRow(feed: $feed)
                    }
                }
                .padding(12)
            }
            Divider()
            HStack {
                Text(store.footerNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(store.windows.count) windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 860, minHeight: 300)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await store.refreshWindows() }
                } label: {
                    Label("Refresh Windows", systemImage: "arrow.clockwise")
                }
                .help("Re-scan capturable windows")
                Button {
                    store.addFeed()
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
                .help("Add another NDI feed")
            }
        }
        .task { await store.onLaunch() }
    }

    @ViewBuilder
    private var permissionBanner: some View {
        switch store.permission {
        case .denied:
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording permission required")
                        .font(.callout.bold())
                    Text("Enable NDI Region in System Settings — or, if you denied the prompt by accident, request it again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Request Again") { store.requestPermissionAgain() }
                Button("Open System Settings") { store.openScreenRecordingSettings() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .grantedNeedsRelaunch:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                Text("Permission granted — relaunch to start capturing.")
                    .font(.callout.bold())
                Spacer()
                Button("Relaunch Now") { store.relaunch() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .granted:
            EmptyView()
        }
    }
}

struct FeedRow: View {
    @EnvironmentObject var store: FeedStore
    @Binding var feed: Feed

    private var isRunning: Bool { store.isRunning(feed.id) }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    TextField("NDI name", text: $feed.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                    windowPicker
                        .frame(maxWidth: .infinity)
                    statusView
                    Button(isRunning ? "Stop" : "Start") {
                        Task {
                            if isRunning {
                                await store.stop(id: feed.id)
                            } else {
                                await store.start(id: feed.id)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isRunning ? .red : .green)
                    Button {
                        Task { await store.removeFeed(id: feed.id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Remove this feed")
                }

                HStack(spacing: 14) {
                    Picker("", selection: $feed.cropMode) {
                        ForEach(CropMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)

                    if feed.cropMode == .bottom {
                        numberField("Height pt", value: $feed.bottom, width: 60)
                    } else {
                        numberField("X", value: $feed.rectX, width: 50)
                        numberField("Y", value: $feed.rectY, width: 50)
                        numberField("W", value: $feed.rectW, width: 50)
                        numberField("H", value: $feed.rectH, width: 50)
                    }
                    intField("Max width px", value: $feed.maxWidth, width: 60)
                    intField("FPS", value: $feed.fps, width: 40)
                    Toggle("Auto-start", isOn: $feed.autoStart)
                        .toggleStyle(.checkbox)
                    Spacer()
                }
                .disabled(isRunning)
            }
            .padding(4)
        }
    }

    private var windowPicker: some View {
        Picker("", selection: Binding<UInt32?>(
            get: { feed.selectedWindowID },
            set: { store.noteSelection(feedID: feed.id, windowID: $0) }
        )) {
            Text("Auto: \(feed.appQuery)").tag(UInt32?.none)
            ForEach(store.windows) { w in
                Text(w.label).tag(UInt32?.some(w.id))
            }
        }
        .labelsHidden()
        .disabled(isRunning)
    }

    @ViewBuilder
    private var statusView: some View {
        switch store.status(feed.id) {
        case .stopped:
            Text("Stopped").font(.caption).foregroundStyle(.secondary)
        case .starting:
            Text("Starting…").font(.caption).foregroundStyle(.orange)
        case .running(let size):
            Label(size, systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.bold())
                .foregroundStyle(.green)
        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: 220)
                .help(message)
        }
    }

    private func numberField(_ caption: String, value: Binding<Double>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }

    private func intField(_ caption: String, value: Binding<Int>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(caption).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }
}
