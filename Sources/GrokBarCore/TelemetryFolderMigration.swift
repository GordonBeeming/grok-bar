import Foundation

/// Moves telemetry written by earlier versions out of `~/Documents`, so macOS stops asking for Documents access.
public struct TelemetryFolderMigration {
    private let home: URL
    private let fileManager: FileManager

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.home = home
        self.fileManager = fileManager
    }

    /// Returns a message per failure. A failure never throws: capture must still write to the new default.
    public func run() -> [String] {
        switch inspectLegacy() {
        case .absent: return []
        case let .unreadable(message):
            return ["Couldn't read the old telemetry folder: \(message)"]
        case let .folder(legacy):
            return moveLegacyFolder(legacy)
        }
    }

    private func moveLegacyFolder(_ legacy: URL) -> [String] {

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: legacy, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []
            )
        } catch { return ["Couldn't read the old telemetry folder: \(error.localizedDescription)"] }

        let destination = TelemetryConfiguration.defaultDirectory(home: home)
        var warnings: [String] = []
        for entry in entries {
            if entry.pathExtension == Self.markExtension {
                let base = entry.deletingPathExtension()
                // Only a regular marker for one of our daily files. A directory named like a marker is someone else's.
                guard Self.isTelemetryFile(base),
                      let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let merging = base.appendingPathExtension(Self.mergingExtension)
                if !fileManager.fileExists(atPath: merging.path) {
                    try? fileManager.removeItem(at: entry)
                }
                continue
            }
            guard let stage = Self.stage(of: entry) else { continue }
            do {
                let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    // removeItem would follow a directory into its contents, so only regular files are ever touched.
                    if stage != .live { warnings.append("Left \(entry.lastPathComponent) alone in the old telemetry folder: it isn't a regular file") }
                    continue
                }
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.path)
                if stage == .migrated || stage == .mergingDone {
                    try fileManager.removeItem(at: entry)
                    continue
                }
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
                let target = destination.appending(path: Self.originalName(of: entry))
                if fileManager.fileExists(atPath: target.path) {
                    try merge(entry, into: target)
                } else {
                    try fileManager.moveItem(at: entry, to: target)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                }
            } catch {
                warnings.append("Couldn't move \(entry.lastPathComponent) out of the old telemetry folder: \(error.localizedDescription)")
            }
        }
        warnings.append(contentsOf: removeLegacyFolderIfEmpty(legacy))
        return warnings
    }

    /// True while a file the migration would still move or finish merging is in the old folder, which means a previous
    /// attempt failed. A `.migrated` leftover is already merged and only needs deleting, so it doesn't count.
    public func hasPendingFiles() -> Bool {
        switch inspectLegacy() {
        case .absent: return false
        case .unreadable: return true
        case let .folder(legacy):
            return folderHasPendingFiles(legacy)
        }
    }

    private func folderHasPendingFiles(_ legacy: URL) -> Bool {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: legacy, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []
            )
        } catch {
            // Unreadable (for example Documents access was denied) isn't empty: files may still be there to move.
            return true
        }
        return entries.contains { entry in
            guard let stage = Self.stage(of: entry), stage == .live || stage == .merging,
                  let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
    }

    private enum LegacyFolder {
        case absent
        case folder(URL)
        case unreadable(String)
    }

    /// A symbolic link is absent: its target isn't ours to move. A permission error is unreadable, not missing,
    /// so the caller keeps retrying instead of recording the migration as finished.
    private func inspectLegacy() -> LegacyFolder {
        let legacy = TelemetryConfiguration.legacyDefaultDirectory(home: home)
        do {
            _ = try fileManager.destinationOfSymbolicLink(atPath: legacy.path)
            return .absent
        } catch {
            if Self.isPermission(error) { return .unreadable(error.localizedDescription) }
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: legacy.path)
            guard (attributes[.type] as? FileAttributeType) == .typeDirectory else { return .absent }
            return .folder(legacy)
        } catch {
            if Self.isMissing(error) { return .absent }
            return .unreadable(error.localizedDescription)
        }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return true }
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(POSIXError.ENOENT.rawValue)
    }

    private static func isPermission(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(POSIXError.EACCES.rawValue)
    }

    /// Appends the old file's complete lines, then deletes it. A trailing unterminated fragment is an unfinished
    /// record that the sink would discard itself, so it isn't carried over.
    /// The source goes through `.merging` (append in progress) and `.migrated` (appended, only needs deleting).
    /// A sibling `.merge-mark` records the destination offset and the byte count before the append, so a crash
    /// after the append does not write those bytes again.
    private func merge(_ source: URL, into target: URL) throws {
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: target.path])
        }
        let incoming = try Data(contentsOf: source)
        guard let lastNewline = incoming.lastIndex(of: 0x0A) else {
            try fileManager.removeItem(at: source)
            return
        }
        let payload = Data(incoming[incoming.startIndex...lastNewline])
        let handle = try FileHandle(forUpdating: target)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size > 0 {
            try handle.seek(toOffset: size - 1)
            // Appending to an unfinished record would corrupt both lines; the sink repairs it on its next write.
            guard try handle.read(upToCount: 1)?.first == 0x0A else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSFilePathErrorKey: target.path,
                    NSLocalizedDescriptionKey: "the existing file ends in an unfinished record; it will be merged on a later launch"
                ])
            }
        }
        let merging = Self.stage(of: source) == .merging
            ? source : source.appendingPathExtension(Self.mergingExtension)
        if merging != source { try fileManager.moveItem(at: source, to: merging) }
        let mark = merging.deletingPathExtension().appendingPathExtension(Self.markExtension)
        let offset = try resumeOffset(mark: mark, end: size, length: payload.count)
        if try contains(payload, at: offset, in: handle) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try finishMerge(merging: merging, mark: mark)
            return
        }
        try append(payload, at: offset, handle: handle, mark: mark)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try finishMerge(merging: merging, mark: mark)
    }

    /// Writes the payload at `offset` only when nothing has been added past an unfinished copy of it.
    /// Captures written after that interrupted append stay where they are, and the payload goes on the end.
    private func append(_ payload: Data, at offset: UInt64, handle: FileHandle, mark: URL) throws {
        let end = try handle.seekToEnd()
        let prefixOnly = try unfinishedPrefixOnly(payload, at: offset, end: end, handle: handle)
        if end == offset || prefixOnly {
            if end != offset { try handle.truncate(atOffset: offset) }
            do {
                try handle.seek(toOffset: offset)
                try handle.write(contentsOf: payload)
                try handle.synchronize()
            } catch {
                try? handle.truncate(atOffset: offset)
                throw error
            }
            return
        }
        let fresh = try handle.seekToEnd()
        try Data("\(fresh) \(payload.count)\n".utf8).write(to: mark, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mark.path)
        do {
            try handle.seek(toOffset: fresh)
            try handle.write(contentsOf: payload)
            try handle.synchronize()
        } catch {
            try? handle.truncate(atOffset: fresh)
            throw error
        }
    }

    private func unfinishedPrefixOnly(_ payload: Data, at offset: UInt64, end: UInt64, handle: FileHandle) throws -> Bool {
        guard end > offset, end < offset + UInt64(payload.count) else { return false }
        let overlap = Int(end - offset)
        try handle.seek(toOffset: offset)
        let present = try handle.read(upToCount: overlap) ?? Data()
        return present == payload.prefix(overlap)
    }

    /// The mark is written before the append. A later run with the same length trusts that offset.
    private func resumeOffset(mark: URL, end: UInt64, length: Int) throws -> UInt64 {
        if let saved = readMark(mark), saved.length == length { return saved.offset }
        try Data("\(end) \(length)\n".utf8).write(to: mark, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mark.path)
        return end
    }

    private func readMark(_ mark: URL) -> (offset: UInt64, length: Int)? {
        guard let text = try? String(contentsOf: mark, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count == 2, let offset = UInt64(parts[0]), let length = Int(parts[1]), length >= 0 else { return nil }
        return (offset, length)
    }

    private func contains(_ payload: Data, at offset: UInt64, in handle: FileHandle) throws -> Bool {
        let end = try handle.seekToEnd()
        guard end >= offset + UInt64(payload.count) else { return false }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: payload.count) == payload
    }

    /// The lines are in the target now, so from here the source must never go back to a name that gets appended again.
    private func finishMerge(merging: URL, mark: URL) throws {
        let base = merging.deletingPathExtension()
        let migrated = base.appendingPathExtension(Self.migratedExtension)
        do {
            try fileManager.moveItem(at: merging, to: migrated)
        } catch {
            do {
                try fileManager.removeItem(at: merging)
            } catch {
                try fileManager.moveItem(at: merging, to: base.appendingPathExtension(Self.mergingDoneExtension))
                throw error
            }
            try? fileManager.removeItem(at: mark)
            return
        }
        try fileManager.removeItem(at: migrated)
        try? fileManager.removeItem(at: mark)
    }

    private func removeLegacyFolderIfEmpty(_ legacy: URL) -> [String] {
        do {
            let remaining = try fileManager.contentsOfDirectory(atPath: legacy.path)
            guard remaining.allSatisfy({ $0 == ".DS_Store" }) else { return [] }
            for name in remaining { try fileManager.removeItem(at: legacy.appending(path: name)) }
            try fileManager.removeItem(at: legacy)
            return []
        } catch { return ["Couldn't remove the old telemetry folder: \(error.localizedDescription)"] }
    }

    private static let mergingExtension = "merging"
    private static let migratedExtension = "migrated"
    private static let markExtension = "merge-mark"

    private static let mergingDoneExtension = "merging-done"

    /// `merging` and `mergingDone` are both leftovers, but only `merging` still needs its lines appended.
    private enum Stage { case live, merging, mergingDone, migrated }

    private static func stage(of url: URL) -> Stage? {
        if isTelemetryFile(url) { return .live }
        guard isTelemetryFile(url.deletingPathExtension()) else { return nil }
        switch url.pathExtension {
        case mergingExtension: return .merging
        case mergingDoneExtension: return .mergingDone
        case migratedExtension: return .migrated
        default: return nil
        }
    }

    private static func originalName(of url: URL) -> String {
        stage(of: url) == .live ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    static func isTelemetryFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasSuffix(".jsonl") else { return false }
        for signal in TelemetrySignal.allCases {
            let prefix = "grokbar-\(signal.rawValue)-"
            guard name.hasPrefix(prefix) else { continue }
            let day = String(name.dropFirst(prefix.count).dropLast(".jsonl".count))
            guard day.count == 10 else { return false }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: day).map { formatter.string(from: $0) == day } ?? false
        }
        return false
    }
}
