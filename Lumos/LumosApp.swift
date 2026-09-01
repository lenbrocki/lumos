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
    @State private var isOn = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(get: { isOn }, set: setEnabled))
                .toggleStyle(.switch)

            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        // ponytail: re-read on appear only; no SMAppService change notification exists.
        .onAppear { isOn = SMAppService.mainApp.status == .enabled }
    }

    private func setEnabled(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isOn = SMAppService.mainApp.status == .enabled
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
