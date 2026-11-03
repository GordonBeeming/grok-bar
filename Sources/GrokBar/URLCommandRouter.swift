import AppKit
import GrokBarCore

extension Notification.Name {
    static let grokBarOpenSettings = Notification.Name("com.gordonbeeming.GrokBar.openSettings")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { URLCommandRouter.shared.handle(url) }
        }
    }
}

/// Handles `grokbar://` links. Any app or web page can open one, so a settings change is
/// always shown for confirmation before it's applied.
@MainActor
final class URLCommandRouter {
    static let shared = URLCommandRouter()

    weak var settings: AppSettings?
    private var isPresenting = false

    func handle(_ url: URL) {
        guard !isPresenting else { return }
        let command: TelemetryURLCommand
        do { command = try TelemetryURLCommand.parse(url) }
        catch {
            inform("GrokBar couldn't use that link", error.localizedDescription)
            return
        }
        switch command {
        case .settings:
            NSApp.activate()
            NotificationCenter.default.post(name: .grokBarOpenSettings, object: nil)
        case let .telemetry(change):
            confirm(change)
        }
    }

    private func confirm(_ change: TelemetrySettingsChange) {
        guard let settings else { return }
        let lines = change.changeLines(from: settings.telemetryConfiguration)
        guard !lines.isEmpty else {
            inform("Telemetry settings are already set", "The link asks for the values GrokBar already uses.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Change GrokBar telemetry settings?"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard present(alert) == .alertFirstButtonReturn else { return }
        if let interval = change.intervalMinutes { settings.telemetryIntervalMinutes = interval }
        if let retention = change.retentionDays { settings.telemetryRetentionDays = retention }
        if let directory = change.directory { settings.telemetryDirectory = directory }
        if let enabled = change.enabled { settings.telemetryEnabled = enabled }
    }

    private func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        isPresenting = true
        defer { isPresenting = false }
        NSApp.activate()
        return alert.runModal()
    }
}
