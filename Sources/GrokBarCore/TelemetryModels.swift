import Foundation
import Synchronization

public struct TelemetryConfiguration: Equatable, Sendable {
    public static let unlimitedRetentionDays = 0
    public let enabled: Bool
    public let intervalMinutes: Int
    public let retentionDays: Int
    public let directory: URL

    public init(enabled: Bool = false, intervalMinutes: Int = 5, retentionDays: Int = 90, directory: URL) {
        self.enabled = enabled
        self.intervalMinutes = min(max(intervalMinutes, 1), 1_440)
        self.retentionDays = Self.normalizedRetentionDays(retentionDays)
        self.directory = directory
    }

    public static func normalizedRetentionDays(_ days: Int) -> Int {
        days == unlimitedRetentionDays ? unlimitedRetentionDays : min(max(days, 1), 3_650)
    }

    public static var defaultDirectory: URL {
        defaultDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Application Support isn't a TCC-protected folder, so macOS doesn't prompt for access the way it does for Documents.
    public static func defaultDirectory(home: URL) -> URL {
        home.appending(path: "Library/Application Support/GrokBar/Telemetry", directoryHint: .isDirectory)
    }

    /// Where a build that followed the first spec draft would have written. Kept so a folder there can move.
    public static func legacyDefaultDirectory(home: URL) -> URL {
        home.appending(path: "Documents/GrokBar Telemetry", directoryHint: .isDirectory)
    }
}

public enum TelemetrySignal: String, Sendable, CaseIterable {
    case metrics, logs
}

public final class TelemetryActivity: Sendable {
    private let enabled = Mutex(true)
    private let retentionDays: Mutex<Int?>

    public init(retentionDays: Int? = nil) {
        self.retentionDays = Mutex(retentionDays.map(TelemetryConfiguration.normalizedRetentionDays))
    }

    public func updateRetentionDays(_ days: Int) {
        retentionDays.withLock { $0 = TelemetryConfiguration.normalizedRetentionDays(days) }
    }

    public func currentRetentionDays(fallback: Int) -> Int {
        retentionDays.withLock { $0 ?? fallback }
    }

    public func stop() { enabled.withLock { $0 = false } }

    public func whileEnabled(_ body: () throws -> Void) throws {
        try enabled.withLock { enabled in
            guard enabled else { throw CancellationError() }
            try body()
        }
    }

    public func check() throws {
        try Task.checkCancellation()
        guard enabled.withLock({ $0 }) else { throw CancellationError() }
    }
}

public protocol TelemetrySink: Sendable {
    func export(_ data: Data, signal: TelemetrySignal, at date: Date, retentionDays: Int, activity: TelemetryActivity?) async throws
    func exportWarnings() async -> [String]
}

public extension TelemetrySink {
    func export(_ data: Data, signal: TelemetrySignal, at date: Date, retentionDays: Int) async throws {
        try await export(data, signal: signal, at: date, retentionDays: retentionDays, activity: nil)
    }

    func exportWarnings() async -> [String] { [] }
}
