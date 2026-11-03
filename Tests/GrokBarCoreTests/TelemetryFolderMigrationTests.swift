import XCTest
@testable import GrokBarCore

private final class UndeletableFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: URL.path])
    }
}

private final class LegacyAttributesDeniedFileManager: FileManager, @unchecked Sendable {
    override func destinationOfSymbolicLink(atPath path: String) throws -> String {
        throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: path])
    }
}

private final class UnreadableFileManager: FileManager, @unchecked Sendable {
    override func contentsOfDirectory(
        at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
    }
}

/// Fails the rename that marks an append as done, and optionally the delete that would follow it.
private final class UnmarkableFileManager: FileManager, @unchecked Sendable {
    let failsDeletes: Bool
    init(failsDeletes: Bool) {
        self.failsDeletes = failsDeletes
        super.init()
    }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.pathExtension == "migrated" {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dstURL.path])
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
    override func removeItem(at URL: URL) throws {
        if failsDeletes { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: URL.path]) }
        try super.removeItem(at: URL)
    }
}

final class TelemetryFolderMigrationTests: XCTestCase {
    private var home: URL!
    private var legacy: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "grokbar-home-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        legacy = TelemetryConfiguration.legacyDefaultDirectory(home: home)
        destination = TelemetryConfiguration.defaultDirectory(home: home)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    func testMovesMatchingFilesAndRemovesEmptyLegacyFolder() throws {
        try write("grokbar-metrics-2026-10-11.jsonl", "m\n", in: legacy)
        try write("grokbar-logs-2026-10-11.jsonl", "l\n", in: legacy)

        let warnings = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(warnings, [])
        XCTAssertEqual(try read("grokbar-metrics-2026-10-11.jsonl", in: destination), "m\n")
        XCTAssertEqual(try read("grokbar-logs-2026-10-11.jsonl", in: destination), "l\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testCreatesDestinationWithPrivatePermissions() throws {
        try write("grokbar-metrics-2026-10-11.jsonl", "m\n", in: legacy)

        _ = TelemetryFolderMigration(home: home).run()

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
        let file = try FileManager.default.attributesOfItem(
            atPath: destination.appending(path: "grokbar-metrics-2026-10-11.jsonl").path
        )
        XCTAssertEqual((file[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    }

    func testLeavesOtherFilesAndKeepsFolderWhenNotEmpty() throws {
        try write("grokbar-metrics-2026-10-11.jsonl", "m\n", in: legacy)
        try write("notes.txt", "mine", in: legacy)
        try write("grokbar-metrics-2026-10-11.jsonl.bak", "bak", in: legacy)
        try write("grokbar-metrics-2026-13-45.jsonl", "bad date", in: legacy)

        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(try read("notes.txt", in: legacy), "mine")
        XCTAssertEqual(try read("grokbar-metrics-2026-10-11.jsonl.bak", in: legacy), "bak")
        XCTAssertEqual(try read("grokbar-metrics-2026-13-45.jsonl", in: legacy), "bad date")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "notes.txt").path))
        XCTAssertEqual(try read("grokbar-metrics-2026-10-11.jsonl", in: destination), "m\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appending(path: "grokbar-metrics-2026-10-11.jsonl").path))
    }

    func testIgnoresDSStoreWhenDecidingIfLegacyFolderIsEmpty() throws {
        try write("grokbar-logs-2026-10-11.jsonl", "l\n", in: legacy)
        try write(".DS_Store", "x", in: legacy)

        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testKeepsDSStoreWhenOtherFilesRemain() throws {
        try write("notes.txt", "mine", in: legacy)
        try write(".DS_Store", "x", in: legacy)

        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(try read(".DS_Store", in: legacy), "x")
        XCTAssertEqual(try read("notes.txt", in: legacy), "mine")
    }

    func testSameNameFileIsAppendedNotOverwritten() throws {
        let name = "grokbar-metrics-2026-10-11.jsonl"
        try write(name, "new1\nnew2\n", in: destination)
        try write(name, "old1\nold2\n", in: legacy)

        let warnings = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(warnings, [])
        XCTAssertEqual(try read(name, in: destination), "new1\nnew2\nold1\nold2\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testMergeAppendsOnlyCompleteLines() throws {
        let name = "grokbar-logs-2026-10-11.jsonl"
        try write(name, "new\n", in: destination)
        try write(name, "old1\nunfinished", in: legacy)

        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(try read(name, in: destination), "new\nold1\n")
    }

    func testMergeIntoUnterminatedDestinationLeavesLegacyFileInPlace() throws {
        let name = "grokbar-logs-2026-10-11.jsonl"
        try write(name, "new-without-newline", in: destination)
        try write(name, "old\n", in: legacy)

        let warnings = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(try read(name, in: destination), "new-without-newline")
        XCTAssertEqual(try read(name, in: legacy), "old\n")
    }

    func testSymbolicLinkedLegacyRootIsNotFollowed() throws {
        let elsewhere = home.appending(path: "elsewhere", directoryHint: .isDirectory)
        try write("grokbar-metrics-2026-10-11.jsonl", "m\n", in: elsewhere)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: elsewhere)
        let migration = TelemetryFolderMigration(home: home)

        XCTAssertEqual(migration.run(), [])
        XCTAssertFalse(migration.hasPendingFiles())
        XCTAssertEqual(try read("grokbar-metrics-2026-10-11.jsonl", in: elsewhere), "m\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPendingFilesOnlyCountEligibleTelemetryFiles() throws {
        let migration = TelemetryFolderMigration(home: home)
        XCTAssertFalse(migration.hasPendingFiles())
        try write("notes.txt", "mine", in: legacy)
        XCTAssertFalse(migration.hasPendingFiles())
        try write("grokbar-logs-2026-10-11.jsonl", "l\n", in: legacy)
        XCTAssertTrue(migration.hasPendingFiles())
    }

    func testFailedDeleteAfterAppendDoesNotAppendAgainOnRetry() throws {
        let name = "grokbar-metrics-2026-10-11.jsonl"
        try write(name, "new\n", in: destination)
        try write(name, "old\n", in: legacy)

        let failing = TelemetryFolderMigration(home: home, fileManager: UndeletableFileManager())
        XCTAssertEqual(failing.run().count, 1)
        XCTAssertFalse(failing.hasPendingFiles())
        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(try read(name, in: destination), "new\nold\n")
    }

    func testLeftoverMergingFileIsMergedAndCleanedUp() throws {
        let name = "grokbar-metrics-2026-10-11.jsonl"
        try write(name, "new\n", in: destination)
        try write("\(name).merging", "old\n", in: legacy)
        let migration = TelemetryFolderMigration(home: home)
        XCTAssertTrue(migration.hasPendingFiles())

        XCTAssertEqual(migration.run(), [])

        XCTAssertEqual(try read(name, in: destination), "new\nold\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testLeftoverMergingFileWithoutDestinationIsMovedIntoPlace() throws {
        let name = "grokbar-logs-2026-10-11.jsonl"
        try write("\(name).merging", "old\n", in: legacy)

        XCTAssertEqual(TelemetryFolderMigration(home: home).run(), [])

        XCTAssertEqual(try read(name, in: destination), "old\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testDirectoriesAndLinksNamedLikeLeftoversAreReportedAndNeverRemoved() throws {
        let name = "grokbar-metrics-2026-10-11.jsonl"
        try write("inside.txt", "keep", in: legacy.appending(path: "\(name).migrated", directoryHint: .isDirectory))
        let outside = home.appending(path: "outside.jsonl")
        try Data("secret\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: legacy.appending(path: "\(name).merging"), withDestinationURL: outside)
        let migration = TelemetryFolderMigration(home: home)

        XCTAssertFalse(migration.hasPendingFiles())
        XCTAssertEqual(migration.run().count, 2)

        XCTAssertEqual(try read("inside.txt", in: legacy.appending(path: "\(name).migrated", directoryHint: .isDirectory)), "keep")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: legacy.appending(path: "\(name).merging").path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "secret\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testFailedMigratedRenameAfterAppendFallsBackToDeletingTheSource() throws {
        let name = "grokbar-metrics-2026-10-11.jsonl"
        try write(name, "new\n", in: destination)
        try write(name, "old\n", in: legacy)

        XCTAssertEqual(TelemetryFolderMigration(home: home, fileManager: UnmarkableFileManager(failsDeletes: false)).run(), [])
        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertEqual(try read(name, in: destination), "new\nold\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testSourceThatCantBeMarkedOrDeletedAfterAppendIsNeverAppendedAgain() throws {
        let name = "grokbar-metrics-2026-10-11.jsonl"
        try write(name, "new\n", in: destination)
        try write(name, "old\n", in: legacy)

        let stuck = TelemetryFolderMigration(home: home, fileManager: UnmarkableFileManager(failsDeletes: true))
        XCTAssertEqual(stuck.run().count, 1)
        XCTAssertFalse(stuck.hasPendingFiles())
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appending(path: "\(name).merging-done").path))

        XCTAssertEqual(TelemetryFolderMigration(home: home).run(), [])

        XCTAssertEqual(try read(name, in: destination), "new\nold\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testLeftoverMigratedFileIsOnlyDeleted() throws {
        let name = "grokbar-metrics-2026-10-11.jsonl"
        try write(name, "new\n", in: destination)
        try write("\(name).migrated", "old\n", in: legacy)
        let migration = TelemetryFolderMigration(home: home)
        XCTAssertFalse(migration.hasPendingFiles())

        XCTAssertEqual(migration.run(), [])

        XCTAssertEqual(try read(name, in: destination), "new\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testAlreadyAppendedMergingFileIsNotAppendedAgain() throws {
        let name = "grokbar-metrics-2026-10-11.jsonl"
        try write(name, "new\nold\n", in: destination)
        try write("\(name).merging", "old\n", in: legacy)
        try Data("4 4\n".utf8).write(to: legacy.appending(path: "\(name).merge-mark"))

        XCTAssertEqual(TelemetryFolderMigration(home: home).run(), [])

        XCTAssertEqual(try read(name, in: destination), "new\nold\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testUnrelatedMergeMarkDirectoryIsLeftAlone() throws {
        let folder = legacy.appending(path: "notes.merge-mark", directoryHint: .isDirectory)
        try write("keep.txt", "mine", in: folder)

        XCTAssertEqual(TelemetryFolderMigration(home: home).run(), [])

        XCTAssertEqual(try read("keep.txt", in: folder), "mine")
    }

    func testRecordsAddedAfterAnInterruptedAppendAreKept() throws {
        let name = "grokbar-metrics-2026-10-11.jsonl"
        try write(name, "new\nKEEP\n", in: destination)
        try write("\(name).merging", "old\n", in: legacy)
        try Data("4 4\n".utf8).write(to: legacy.appending(path: "\(name).merge-mark"))

        XCTAssertEqual(TelemetryFolderMigration(home: home).run(), [])

        XCTAssertEqual(try read(name, in: destination), "new\nKEEP\nold\n")
    }

    func testPermissionErrorOnTheLegacyFolderStaysPending() throws {
        try write("grokbar-metrics-2026-10-11.jsonl", "m\n", in: legacy)
        let migration = TelemetryFolderMigration(home: home, fileManager: LegacyAttributesDeniedFileManager())

        XCTAssertEqual(migration.run().count, 1)
        XCTAssertTrue(migration.hasPendingFiles())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUnreadableLegacyFolderCountsAsPendingSoItIsRetried() throws {
        try write("grokbar-metrics-2026-10-11.jsonl", "m\n", in: legacy)
        let migration = TelemetryFolderMigration(home: home, fileManager: UnreadableFileManager())

        XCTAssertEqual(migration.run().count, 1)
        XCTAssertTrue(migration.hasPendingFiles())
    }

    func testNoLegacyFolderIsANoOp() {
        XCTAssertEqual(TelemetryFolderMigration(home: home).run(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDoesNotMoveSymbolicLinks() throws {
        let outside = home.appending(path: "outside.jsonl")
        try Data("secret\n".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: legacy.appending(path: "grokbar-metrics-2026-10-11.jsonl"), withDestinationURL: outside
        )

        _ = TelemetryFolderMigration(home: home).run()

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "grokbar-metrics-2026-10-11.jsonl").path))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: legacy.appending(path: "grokbar-metrics-2026-10-11.jsonl").path
        ))
    }

    private func write(_ name: String, _ content: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: directory.appending(path: name))
    }

    private func read(_ name: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appending(path: name), encoding: .utf8)
    }
}
