import Foundation
import GrokBarCore

struct UsageSnapshot: Sendable {
    let limits: [UsageLimit]
    let planType: String?
    let prepaidUSD: Double?
}

enum GrokClientError: Error, LocalizedError {
    case processFailed
    case noUsage

    var errorDescription: String? {
        switch self {
        case .processFailed:
            return "Grok stopped before returning usage"
        case .noUsage:
            return "Grok usage isn't available"
        }
    }
}

protocol UsageFetching: Sendable {
    func fetchUsage() async throws -> UsageSnapshot
}

struct GrokAgentClient: UsageFetching {
    private let locator = GrokExecutableLocator()

    func fetchUsage() async throws -> UsageSnapshot {
        let executable = try locator.locate()
        let data = try await Task.detached(priority: .utility) {
            try Self.runProbe(executable: executable)
        }.value
        let probe = try BillingResponseParser.parse(data)
        guard let billing = probe.billing else { throw GrokClientError.noUsage }
        let limits = UsageLimitMapper.limits(from: billing)
        guard !limits.isEmpty else { throw GrokClientError.noUsage }
        return UsageSnapshot(
            limits: limits,
            planType: UsageLimitMapper.planType(from: billing),
            prepaidUSD: UsageLimitMapper.prepaidUSD(from: billing)
        )
    }

    static func runProbe(executable: URL) throws -> Data {
        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = executable
        process.arguments = ["agent", "stdio"]
        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = executable.deletingLastPathComponent().path
        environment["PATH"] = environment["PATH"]
            .flatMap { $0.isEmpty ? nil : "\(executableDirectory):\($0)" } ?? executableDirectory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()

        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
        }

        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": [
                "protocolVersion": "1",
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false
                ],
                "clientInfo": [
                    "name": "grok_bar",
                    "title": "GrokBar",
                    "version": "0.1.0"
                ]
            ]
        ]
        try write([initialize], to: input.fileHandleForWriting)

        var response = Data()
        guard read(until: [0], from: output.fileHandleForReading, into: &response) else {
            throw GrokClientError.processFailed
        }

        let billing: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "_x.ai/billing",
            "params": [:]
        ]
        try write([billing], to: input.fileHandleForWriting)
        guard read(until: [1], from: output.fileHandleForReading, into: &response) else {
            throw GrokClientError.processFailed
        }

        try input.fileHandleForWriting.close()
        response.append(output.fileHandleForReading.readDataToEndOfFile())
        process.waitUntilExit()

        guard process.terminationStatus == 0 || !response.isEmpty else {
            throw GrokClientError.processFailed
        }
        return response
    }

    private static func write(_ messages: [[String: Any]], to handle: FileHandle) throws {
        let request = try messages.reduce(into: Data()) { data, message in
            let encoded = try JSONSerialization.data(withJSONObject: message)
            let literal = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
            data.append(Data(literal.utf8))
            data.append(0x0A)
        }
        try handle.write(contentsOf: request)
    }

    private static func read(until expectedIDs: Set<Int>, from handle: FileHandle, into response: inout Data) -> Bool {
        while !expectedIDs.isSubset(of: responseIDs(in: response)) {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return false }
            response.append(chunk)
        }
        return true
    }

    private static func responseIDs(in data: Data) -> Set<Int> {
        Set(data.split(separator: 0x0A).compactMap { line in
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let dictionary = object as? [String: Any],
                let id = dictionary["id"] as? Int
            else { return nil }
            return id
        })
    }
}
