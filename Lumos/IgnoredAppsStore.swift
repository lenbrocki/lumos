import AppKit
import Foundation

/// An installed or running application that can be added to the pause list by search.
struct AppCandidate: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// Finds applications to offer in the "add paused app" search: installed bundles in the standard
/// Applications folders plus anything currently running (covers apps launched from elsewhere).
enum AppCatalog {
    /// Scans the filesystem, so call it off the main thread. Sorted by name, one entry per bundle ID.
    static func load() -> [AppCandidate] {
        let fm = FileManager.default
        var roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/Applications/Utilities"].map { URL(fileURLWithPath: $0) }
        roots.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))

        var byID: [String: AppCandidate] = [:]
        func add(_ bundleID: String?, _ name: String?) {
            guard let bundleID, let name, !name.isEmpty,
                  bundleID != Bundle.main.bundleIdentifier, byID[bundleID] == nil else { return }
            byID[bundleID] = AppCandidate(bundleID: bundleID, name: name)
        }

        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            // Apps sit at the top level or one folder down (e.g. "/Applications/Adobe Photoshop/").
            var appURLs = items.filter { $0.pathExtension == "app" }
            for dir in items where dir.pathExtension.isEmpty {
                let nested = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? []
                appURLs += nested.filter { $0.pathExtension == "app" }
            }
            for url in appURLs {
                let bundle = Bundle(url: url)
                add(bundle?.bundleIdentifier, fm.displayName(atPath: url.path)
                    .replacingOccurrences(of: ".app", with: ""))
            }
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            add(app.bundleIdentifier, app.localizedName)
        }

        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// One application for which auto-brightness is paused, plus the backlight level it should
/// hold — remembered per display so each panel keeps its own preferred level for the app.
struct IgnoredApp: Codable, Equatable {
    var bundleID: String
    var name: String
    /// Preferred backlight level (0...1) per display, keyed by `DisplayInfo.persistKey`.
    var preferred: [String: Double] = [:]
}

/// Persistent set of apps that pause content-adaptive brightness while frontmost, each holding
/// a remembered per-display level. Inspired by lumen's ignore list, adapted to Lumos's
/// multi-display model (lumen remembered a single level for the main display).
///
/// Small structured config, so it lives in `UserDefaults` rather than the per-display curve files.
final class IgnoredAppsStore {
    private static let defaultsKey = "ignoredApps.v1"
    private var apps: [String: IgnoredApp]   // keyed by bundleID

    init() { apps = Self.load() }

    /// Ignored apps, sorted by name for stable display.
    var all: [IgnoredApp] {
        apps.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func isIgnored(_ bundleID: String) -> Bool { apps[bundleID] != nil }

    func add(bundleID: String, name: String) {
        guard apps[bundleID] == nil else { return }
        apps[bundleID] = IgnoredApp(bundleID: bundleID, name: name)
        save()
    }

    func remove(bundleID: String) {
        guard apps[bundleID] != nil else { return }
        apps[bundleID] = nil
        save()
    }

    func preferredBrightness(bundleID: String, persistKey: String) -> Double? {
        apps[bundleID]?.preferred[persistKey]
    }

    func setPreferredBrightness(_ value: Double, bundleID: String, persistKey: String) {
        guard var app = apps[bundleID] else { return }
        app.preferred[persistKey] = value
        apps[bundleID] = app
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(apps) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [String: IgnoredApp] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: IgnoredApp].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
