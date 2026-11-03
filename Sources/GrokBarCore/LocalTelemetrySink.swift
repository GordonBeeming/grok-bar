import Foundation

public actor LocalTelemetrySink: TelemetrySink {
    public let directory: URL
    private var warnings: [String] = []

    public init(directory: URL) { self.directory = directory }

    public func export(
        _ data: Data, signal: TelemetrySignal, at date: Date, retentionDays: Int, activity: TelemetryActivity? = nil
    ) throws {
        try Task.checkCancellation()
        let produced: [String]
        if let activity {
            produced = try activity.whileEnabled {
                try Self.write(data, signal: signal, at: date, directory: self.directory,
                               retentionDays: retentionDays, activity: activity)
            }
        } else {
            produced = try Self.write(data, signal: signal, at: date, directory: directory,
                                      retentionDays: retentionDays, activity: nil)
        }
        warnings.append(contentsOf: produced)
    }

    /// Runs while the caller holds `TelemetryActivity.whileEnabled`, so it must not call `activity.check()`.
    private static func write(
        _ data: Data, signal: TelemetrySignal, at date: Date, directory: URL,
        retentionDays: Int, activity: TelemetryActivity?
    ) throws -> [String] {
        var warnings: [String] = []
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let currentRetention = activity?.currentRetentionDays(fallback: retentionDays) ?? retentionDays
        do { try prune(at: date, directory: directory, retentionDays: currentRetention, activity: activity, warnings: &warnings) }
        catch is CancellationError { throw CancellationError() }
        catch { warnings.append("Couldn't finish telemetry retention cleanup: \(error.localizedDescription)") }
        let file = directory.appending(path: "grokbar-\(signal.rawValue)-\(dayString(date)).jsonl")
        if !manager.fileExists(atPath: file.path) {
            guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
            }
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: file.path])
        }
        // createFile's mode is masked by umask, and an older file may still be world-readable.
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forUpdating: file)
        do {
            try repairUnfinishedRecord(handle, warnings: &warnings)
            try handle.seekToEnd()
            var line = data
            line.append(0x0A)
            try handle.write(contentsOf: line)
            try handle.synchronize()
        } catch {
            try handle.close()
            throw error
        }
        try handle.close()
        return warnings
    }

    public func exportWarnings() async -> [String] {
        defer { warnings = [] }
        return warnings
    }

    private static func repairUnfinishedRecord(_ handle: FileHandle, warnings: inout [String]) throws {
        let size = try handle.seekToEnd()
        guard size > 0 else { return }
        try handle.seek(toOffset: size - 1)
        if try handle.read(upToCount: 1)?.first == 0x0A { return }
        var offset = size
        while offset > 0 {
            let length = min(offset, 65_536)
            offset -= length
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: Int(length)) else { throw CocoaError(.fileReadCorruptFile) }
            if let newline = chunk.lastIndex(of: 0x0A) {
                try handle.truncate(atOffset: offset + UInt64(newline) + 1)
                warnings.append("Recovered an unfinished telemetry record")
                return
            }
        }
        try handle.truncate(atOffset: 0)
        warnings.append("Recovered an unfinished telemetry record")
    }

    private static func prune(
        at date: Date, directory: URL, retentionDays: Int, activity: TelemetryActivity?, warnings: inout [String]
    ) throws {
        guard retentionDays != TelemetryConfiguration.unlimitedRetentionDays else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let cutoff = calendar.date(byAdding: .day, value: -(max(1, retentionDays) - 1),
                                         to: calendar.startOfDay(for: date)) else {
            throw CocoaError(.coderInvalidValue)
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let formatter = dayFormatter()
        for entry in entries {
            if let activity, activity.currentRetentionDays(fallback: retentionDays) != retentionDays { return }
            let name = entry.lastPathComponent
            guard let signal = TelemetrySignal.allCases.first(where: {
                name.hasPrefix("grokbar-\($0.rawValue)-")
            }), name.hasSuffix(".jsonl") else { continue }
            let day = String(name.dropFirst("grokbar-\(signal.rawValue)-".count).dropLast(6))
            guard day.count == 10, let fileDate = formatter.date(from: day),
                  formatter.string(from: fileDate) == day, fileDate < cutoff else { continue }
            do {
                let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try FileManager.default.removeItem(at: entry)
            } catch { warnings.append("Couldn't remove expired telemetry: \(error.localizedDescription)") }
        }
    }

    private static func dayString(_ date: Date) -> String { dayFormatter().string(from: date) }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
