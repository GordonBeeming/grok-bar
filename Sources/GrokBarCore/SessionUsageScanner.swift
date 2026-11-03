import Foundation

public struct TokenTypeCounts: Codable, Sendable, Equatable {
    public var input: Int64 = 0
    public var cacheRead: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var output: Int64 = 0
    public var reasoning: Int64 = 0

    public init() {}
}

/// Where each `usage.json` has been read up to. Totals only move forward from the moment tracking starts.
public struct SessionScanState: Codable, Sendable, Equatable {
    struct RawTotals: Codable, Sendable, Equatable {
        var input: Int64
        var cacheRead: Int64
        var cacheWrite: Int64
        var output: Int64
        var reasoning: Int64
        var total: Int64
    }

    var cursors: [String: [String: RawTotals]]
    public internal(set) var totals: [String: TokenTypeCounts]
    public let countingSince: Date
    /// Paths that existed when counting started but could not be read. The first good read sets a cursor and counts nothing.
    var unreadAtBaseline: Set<String>

    init(
        cursors: [String: [String: RawTotals]],
        totals: [String: TokenTypeCounts],
        countingSince: Date,
        unreadAtBaseline: Set<String> = []
    ) {
        self.cursors = cursors
        self.totals = totals
        self.countingSince = countingSince
        self.unreadAtBaseline = unreadAtBaseline
    }

    private enum CodingKeys: String, CodingKey {
        case cursors, totals, countingSince, unreadAtBaseline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursors = try container.decode([String: [String: RawTotals]].self, forKey: .cursors)
        totals = try container.decode([String: TokenTypeCounts].self, forKey: .totals)
        countingSince = try container.decode(Date.self, forKey: .countingSince)
        unreadAtBaseline = try container.decodeIfPresent(Set<String>.self, forKey: .unreadAtBaseline) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cursors, forKey: .cursors)
        try container.encode(totals, forKey: .totals)
        try container.encode(countingSince, forKey: .countingSince)
        try container.encode(unreadAtBaseline, forKey: .unreadAtBaseline)
    }
}

/// Counts tokens from Grok session `usage.json` files under `GROK_HOME` (default `~/.grok`).
public struct SessionUsageScanner: Sendable {
    public struct ScanFailure: Sendable, Equatable {
        public let file: String
        public let message: String
    }

    private let root: URL
    static let unknownModel = "unknown"

    public init(grokHome: URL) {
        root = grokHome.appending(path: "sessions", directoryHint: .isDirectory)
    }

    /// Places cursors at the files that already exist and counts nothing. Later growth is what's counted.
    public func baseline(now: Date) throws -> SessionScanState {
        var state = SessionScanState(cursors: [:], totals: [:], countingSince: now)
        for url in try usageFiles() {
            do {
                state.cursors[url.path] = try Self.rawTotals(in: url)
            } catch {
                state.unreadAtBaseline.insert(url.path)
            }
        }
        return state
    }

    public func scan(_ state: inout SessionScanState) throws -> [ScanFailure] {
        var failures: [ScanFailure] = []
        for url in try usageFiles() {
            let current: [String: SessionScanState.RawTotals]
            do { current = try Self.rawTotals(in: url) }
            catch {
                failures.append(ScanFailure(file: url.lastPathComponent, message: error.localizedDescription))
                continue
            }
            if state.unreadAtBaseline.remove(url.path) != nil {
                state.cursors[url.path] = current
                continue
            }
            let previous = state.cursors[url.path] ?? [:]
            var stored = previous
            for model in Set(current.keys).union(previous.keys).sorted() {
                guard let next = current[model] else { continue }
                let delta = Self.delta(from: previous[model], to: next)
                try Self.add(delta, model: model, to: &state.totals)
                stored[model] = Self.highWater(from: previous[model], to: next)
            }
            state.cursors[url.path] = stored
        }
        return failures
    }

    private func usageFiles() throws -> [URL] {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path])
        }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if let enumerationError { throw enumerationError }
            guard url.lastPathComponent == "usage.json" else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            files.append(url)
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.path < $1.path }
    }

    /// Keeps a field that dipped while the total did not, so the dip is not counted again when the field returns.
    static func highWater(from previous: SessionScanState.RawTotals?, to next: SessionScanState.RawTotals) -> SessionScanState.RawTotals {
        guard let previous, next.total >= previous.total else { return next }
        return SessionScanState.RawTotals(
            input: max(previous.input, next.input),
            cacheRead: max(previous.cacheRead, next.cacheRead),
            cacheWrite: max(previous.cacheWrite, next.cacheWrite),
            output: max(previous.output, next.output),
            reasoning: max(previous.reasoning, next.reasoning),
            total: max(previous.total, next.total)
        )
    }

    static func delta(from previous: SessionScanState.RawTotals?, to next: SessionScanState.RawTotals) -> SessionScanState.RawTotals {
        guard let previous else { return next }
        if next.total < previous.total { return next }
        func grown(_ next: Int64, _ previous: Int64) -> Int64 { max(0, next - previous) }
        return SessionScanState.RawTotals(
            input: grown(next.input, previous.input),
            cacheRead: grown(next.cacheRead, previous.cacheRead),
            cacheWrite: grown(next.cacheWrite, previous.cacheWrite),
            output: grown(next.output, previous.output),
            reasoning: grown(next.reasoning, previous.reasoning),
            total: grown(next.total, previous.total)
        )
    }

    /// Grok's `inputTokens` include cache reads. When `total == input + output`, cache creation is inside input too.
    static func split(_ raw: SessionScanState.RawTotals) -> TokenTypeCounts {
        let writesInside = raw.total == raw.input + raw.output
        var counts = TokenTypeCounts()
        let uncached = raw.input - raw.cacheRead - (writesInside ? raw.cacheWrite : 0)
        counts.input = max(uncached, 0)
        counts.cacheRead = max(raw.cacheRead, 0)
        counts.cacheWrite = max(raw.cacheWrite, 0)
        counts.output = max(raw.output, 0)
        counts.reasoning = max(raw.reasoning, 0)
        return counts
    }

    private static func add(_ raw: SessionScanState.RawTotals, model: String, to totals: inout [String: TokenTypeCounts]) throws {
        let split = split(raw)
        var counts = totals[model] ?? TokenTypeCounts()
        counts.input = try sum(counts.input, split.input)
        counts.cacheRead = try sum(counts.cacheRead, split.cacheRead)
        counts.cacheWrite = try sum(counts.cacheWrite, split.cacheWrite)
        counts.output = try sum(counts.output, split.output)
        counts.reasoning = try sum(counts.reasoning, split.reasoning)
        let empty = counts.input == 0 && counts.cacheRead == 0 && counts.cacheWrite == 0 && counts.output == 0 && counts.reasoning == 0
        if !empty { totals[model] = counts }
    }

    private static func sum(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, rhs >= 0 else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    private static func rawTotals(in url: URL) throws -> [String: SessionScanState.RawTotals] {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(UsageFile.self, from: data)
        let usage = file.session?.modelUsage ?? [:]
        if !usage.isEmpty {
            return usage.mapValues(Self.raw)
        }
        if let session = file.session, session.totalTokens != nil || session.inputTokens != nil {
            let model = session.primaryModelId.flatMap { $0.isEmpty ? nil : $0 } ?? unknownModel
            return [model: raw(ModelUsage(
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                cachedReadTokens: session.cachedReadTokens,
                cacheCreationTokens: session.cacheCreationTokens,
                reasoningTokens: session.reasoningTokens,
                totalTokens: session.totalTokens
            ))]
        }
        return [:]
    }

    private static func raw(_ usage: ModelUsage) -> SessionScanState.RawTotals {
        SessionScanState.RawTotals(
            input: usage.inputTokens ?? 0,
            cacheRead: usage.cachedReadTokens ?? 0,
            cacheWrite: usage.cacheCreationTokens ?? 0,
            output: usage.outputTokens ?? 0,
            reasoning: usage.reasoningTokens ?? 0,
            total: usage.totalTokens ?? 0
        )
    }

    private struct UsageFile: Decodable {
        let session: SessionBody?
    }

    private struct SessionBody: Decodable {
        let inputTokens: Int64?
        let outputTokens: Int64?
        let cachedReadTokens: Int64?
        let cacheCreationTokens: Int64?
        let reasoningTokens: Int64?
        let totalTokens: Int64?
        let primaryModelId: String?
        let modelUsage: [String: ModelUsage]?
    }

    private struct ModelUsage: Decodable {
        let inputTokens: Int64?
        let outputTokens: Int64?
        let cachedReadTokens: Int64?
        let cacheCreationTokens: Int64?
        let reasoningTokens: Int64?
        let totalTokens: Int64?
    }
}
