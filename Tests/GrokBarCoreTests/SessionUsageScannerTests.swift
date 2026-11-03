import Foundation
import XCTest
@testable import GrokBarCore

final class SessionUsageScannerTests: XCTestCase {
    func testBaselineCountsNothingAndGrowthIsSplit() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "grokbar-sessions-\(UUID())", directoryHint: .isDirectory)
        let session = home.appending(path: "sessions/workspace/session-a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let file = session.appending(path: "usage.json")
        try write(file, input: 100, output: 40, cacheRead: 30, cacheWrite: 10, reasoning: 5, total: 140)

        let scanner = SessionUsageScanner(grokHome: home)
        var state = try scanner.baseline(now: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(state.totals.isEmpty)
        XCTAssertEqual(try scanner.scan(&state).count, 0)
        XCTAssertTrue(state.totals.isEmpty)

        try write(file, input: 180, output: 50, cacheRead: 40, cacheWrite: 20, reasoning: 8, total: 230)
        XCTAssertEqual(try scanner.scan(&state).count, 0)
        let counts = try XCTUnwrap(state.totals["grok-4.7"])
        // Delta input 80 includes cache read 10 and cache write 10, because total == input + output.
        XCTAssertEqual(counts.input, 60)
        XCTAssertEqual(counts.cacheRead, 10)
        XCTAssertEqual(counts.cacheWrite, 10)
        XCTAssertEqual(counts.output, 10)
        XCTAssertEqual(counts.reasoning, 3)

        XCTAssertEqual(try scanner.scan(&state).count, 0)
        XCTAssertEqual(state.totals["grok-4.7"], counts)
    }

    func testOneBadUsageFileDoesNotBackfillWhenItBecomesReadable() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "grokbar-sessions-\(UUID())", directoryHint: .isDirectory)
        let good = home.appending(path: "sessions/ok/session", directoryHint: .isDirectory)
        let bad = home.appending(path: "sessions/bad/session", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try write(good.appending(path: "usage.json"), input: 10, output: 2, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 12)
        try Data("{".utf8).write(to: bad.appending(path: "usage.json"))

        let scanner = SessionUsageScanner(grokHome: home)
        var state = try scanner.baseline(now: Date())
        XCTAssertTrue(state.totals.isEmpty)
        XCTAssertEqual(state.unreadAtBaseline.count, 1)

        try write(bad.appending(path: "usage.json"), input: 100, output: 20, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 120)
        XCTAssertEqual(try scanner.scan(&state).count, 0)
        XCTAssertTrue(state.totals.isEmpty)
        XCTAssertTrue(state.unreadAtBaseline.isEmpty)

        try write(bad.appending(path: "usage.json"), input: 110, output: 25, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 135)
        _ = try scanner.scan(&state)
        let counts = try XCTUnwrap(state.totals["grok-4.7"])
        XCTAssertEqual(counts.input, 10)
        XCTAssertEqual(counts.output, 5)
    }

    func testSessionsPathThatIsAFileFailsTheScan() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "grokbar-sessions-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: home.appending(path: "sessions"))
        let scanner = SessionUsageScanner(grokHome: home)
        XCTAssertThrowsError(try scanner.baseline(now: Date()))
    }

    func testNewFileAfterBaselineIsCounted() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "grokbar-sessions-\(UUID())", directoryHint: .isDirectory)
        let scanner = SessionUsageScanner(grokHome: home)
        var state = try scanner.baseline(now: Date())
        let session = home.appending(path: "sessions/one/session-b", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try write(session.appending(path: "usage.json"), input: 20, output: 5, cacheRead: 4, cacheWrite: 0, reasoning: 1, total: 25)
        _ = try scanner.scan(&state)
        let counts = try XCTUnwrap(state.totals["grok-4.7"])
        XCTAssertEqual(counts.input, 16)
        XCTAssertEqual(counts.cacheRead, 4)
        XCTAssertEqual(counts.output, 5)
        XCTAssertEqual(counts.reasoning, 1)
    }

    private func write(
        _ url: URL, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int, total: Int
    ) throws {
        let json = """
        {"session":{"primaryModelId":"grok-4.7","modelUsage":{"grok-4.7":{"inputTokens":\(input),"outputTokens":\(output),"cachedReadTokens":\(cacheRead),"cacheCreationTokens":\(cacheWrite),"reasoningTokens":\(reasoning),"totalTokens":\(total)}}}}
        """
        try Data(json.utf8).write(to: url)
    }
}
