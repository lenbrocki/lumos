import AppKit
import ServiceManagement
import SwiftUI

@main
struct LumosApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra("Lumos", systemImage: state.isEnabled ? "sun.max.fill" : "sun.max") {
            ContentView(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Auto-brightness", isOn: Binding(
                get: { state.isEnabled },
                set: { state.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .font(.headline)

            if !state.builtInBrightnessAvailable {
                Label("Brightness control unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if state.isEnabled {
                if state.displays.isEmpty {
                    Text("Detecting displays…").foregroundStyle(.secondary)
                } else {
                    ForEach(state.displays) { display in
                        DisplayRow(state: state, display: display)
                    }
                }

                Divider()
                PauseSection(state: state)
            }

            if let error = state.lastErrorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()
            LaunchAtLoginToggle()

            Divider()
            Button("Quit Lumos") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { state.popoverAppeared() }
        .onDisappear { state.popoverDisappeared() }
    }

}

/// Login item toggle. `SMAppService` owns the state, so nothing is persisted here — the
/// registration itself is the source of truth.
struct LaunchAtLoginToggle: View {
    // Deliberately not seeded from `SMAppService.mainApp.status`: this view is rebuilt on every
    // flush while the popover is open (~5/s), and that status call is a blocking system query
    // whose result SwiftUI would throw away after the first one. `onAppear` reads it instead.
    @State private var isOn = false
    @State private var error: String?
    @State private var needsSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(get: { isOn }, set: setEnabled))
                .toggleStyle(.switch)

            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }

            if needsSettings {
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
        .onAppear { refreshFromSystem() }
    }

    /// Re-read on appear only; there's no SMAppService change notification to observe. This also
    /// covers the user flipping Lumos off in System Settings while the app is running.
    private func refreshFromSystem() {
        let status = SMAppService.mainApp.status
        isOn = status == .enabled

        if status == .requiresApproval {
            error = "Lumos needs to be approved in Login Items."
            needsSettings = true
        } else {
            error = nil
            needsSettings = false
        }
    }

    private func setEnabled(_ on: Bool) {
        var failure: String?
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // These localize to bare domain codes ("SMAppServiceErrorDomain error 1"), which
            // tells the user nothing — say what failed and point at System Settings instead.
            failure = on ? "Couldn't turn on launch at login." : "Couldn't turn off launch at login."
        }

        refreshFromSystem()

        // `register()` can return without throwing while the system still leaves the item off,
        // so trust `status` over what was asked for and never show an unexplained snap-back.
        if failure == nil, isOn != on {
            failure = "macOS didn't accept the change."
        }
        // A `requiresApproval` message from refreshFromSystem() is more specific; keep it.
        if let failure, error == nil {
            error = failure
            needsSettings = true
        }
    }
}

/// Per-app pause (ignore list): turn auto-brightness off for the current app, and manage the
/// list of paused apps. A paused app holds whatever brightness you last set while in it.
struct PauseSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pause for an app").font(.caption).foregroundStyle(.secondary)

            if let app = state.currentApp {
                Toggle(isOn: Binding(
                    get: { app.isIgnored },
                    set: { _ in state.togglePauseForCurrentApp() }
                )) {
                    Text(app.name).lineLimit(1)
                }
                .toggleStyle(.switch)
                .help("Hold a fixed brightness while \(app.name) is frontmost")
            } else {
                Text("Switch to another app to pause it here.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // Other paused apps (the current one is already shown above with its toggle).
            ForEach(state.ignoredApps.filter { $0.id != state.currentApp?.bundleID }) { app in
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Button {
                        state.removeIgnoredApp(app.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Resume auto-brightness for \(app.name)")
                }
                .font(.caption)
            }
        }
    }
}

struct DisplayRow: View {
    @ObservedObject var state: AppState
    let display: AppState.DisplayVM

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                Text(display.name).fontWeight(.medium).lineLimit(1)
                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: "sun.min")
                Slider(
                    value: Binding(
                        get: { display.brightness },
                        set: { state.previewBrightness(display.id, $0) }
                    ),
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        if !editing { state.commitBrightness(display.id, display.brightness) }
                    }
                )
                Image(systemName: "sun.max")
            }

            HStack {
                Text("luminance \(Int((display.luminance * 100).rounded()))%")
                Spacer()
                Text("brightness \(Int((display.brightness * 100).rounded()))%")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
