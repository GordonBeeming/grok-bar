import Foundation

struct TelemetryState: Codable, Sendable, Equatable {
    var scan: SessionScanState?
    var limits: [String: ObservedLimit]?
    var startAnnounced: Bool?
}

public actor TelemetryRecorder {
    private let sink: any TelemetrySink
    private var retentionDays: Int { activity.currentRetentionDays(fallback: 90) }
    private let serviceVersion: String
    private let intervalMinutes: Int
    private let stateURL: URL
    private let scanner: SessionUsageScanner
    private var state: TelemetryState?
    private var warnings: [String] = []
    private let activity: TelemetryActivity

    public init(
        sink: any TelemetrySink,
        retentionDays: Int,
        serviceVersion: String,
        intervalMinutes: Int = 5,
        stateURL: URL,
        scanner: SessionUsageScanner
    ) {
        self.sink = sink
        self.activity = TelemetryActivity(retentionDays: retentionDays)
        self.serviceVersion = serviceVersion
        self.intervalMinutes = intervalMinutes
        self.stateURL = stateURL
        self.scanner = scanner
    }

    public static var defaultStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/GrokBar/telemetry-state.json")
    }

    public static func discardState(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func recordSample(
        limits: [UsageLimit]?,
        prepaidUSD: Double?,
        at date: Date
    ) async throws {
        try activity.check()
        var current = loadState()
        var events: [OTLPTelemetryEncoder.Event] = []

        if var scan = current.scan {
            do {
                for failure in try scanner.scan(&scan) {
                    warnings.append("Couldn't read Grok session \(failure.file): \(failure.message)")
                }
                current.scan = scan
            } catch is CancellationError { throw CancellationError() }
            catch { warnings.append("Couldn't read Grok sessions: \(error.localizedDescription)") }
        } else {
            try startTracking(&current, at: date)
        }
        if current.startAnnounced == false {
            events.append(BarEvents.trackingStarted(intervalMinutes: intervalMinutes))
        }
        var progress = loadState()
        progress.scan = current.scan
        progress.limits = current.limits
        progress.startAnnounced = current.startAnnounced
        if progress != loadState() { try save(progress) }

        var observed = current.limits
        if let limits {
            let barLimits = BarLimit.limits(from: limits)
            events += BarEvents.limitEvents(previous: current.limits, current: barLimits, now: date)
            observed = BarEvents.observed(barLimits)
        }

        let data = try OTLPTelemetryEncoder.metrics(
            limits: limits ?? [],
            prepaidUSD: prepaidUSD,
            capturedAt: date,
            serviceVersion: serviceVersion,
            tokens: current.scan
        )
        try await sink.export(data, signal: .metrics, at: date, retentionDays: retentionDays, activity: activity)
        try activity.check()
        if !events.isEmpty {
            let logs = try OTLPTelemetryEncoder.logs(events, at: date, serviceVersion: serviceVersion)
            try await sink.export(logs, signal: .logs, at: date, retentionDays: retentionDays, activity: activity)
        }
        var saved = loadState()
        saved.limits = observed
        if saved.startAnnounced == false { saved.startAnnounced = true }
        try save(saved)
    }

    public nonisolated func updateRetentionDays(_ days: Int) { activity.updateRetentionDays(days) }
    public nonisolated func stop() { activity.stop() }

    public func exportWarnings() async -> [String] {
        let own = warnings
        warnings = []
        return own + (await sink.exportWarnings())
    }

    private func startTracking(_ state: inout TelemetryState, at date: Date) throws {
        do {
            state.scan = try scanner.baseline(now: date)
            state.limits = nil
            state.startAnnounced = false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            warnings.append("Couldn't start counting Grok tokens: \(error.localizedDescription)")
        }
    }

    private func loadState() -> TelemetryState {
        if let state { return state }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return TelemetryState() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let loaded = try decoder.decode(TelemetryState.self, from: Data(contentsOf: stateURL))
            state = loaded
            return loaded
        } catch {
            warnings.append("Tracking state was unreadable, so token counting restarted: \(error.localizedDescription)")
            state = TelemetryState()
            return TelemetryState()
        }
    }

    private func save(_ newState: TelemetryState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(newState)
        try activity.whileEnabled {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        }
        state = newState
    }
}
