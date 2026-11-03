import Foundation
import XCTest
@testable import GrokBarCore

final class TelemetryContractTests: XCTestCase {
    func testURLAcceptsASubsetAndRejectsABadInterval() throws {
        let change = try TelemetryURLCommand.parse(XCTUnwrap(URL(string: "grokbar://telemetry?enabled=1&interval=7&retention=0&folder=%2FUsers%2Fme%2FTelemetry&utm=x")))
        XCTAssertEqual(change, .telemetry(TelemetrySettingsChange(enabled: true, intervalMinutes: 7, retentionDays: 0, directory: "/Users/me/Telemetry")))
        XCTAssertEqual(try TelemetryURLCommand.parse(XCTUnwrap(URL(string: "grokbar://settings"))), .settings)
        XCTAssertThrowsError(try TelemetryURLCommand.parse(XCTUnwrap(URL(string: "grokbar://telemetry?interval=0"))))
        XCTAssertThrowsError(try TelemetryURLCommand.parse(XCTUnwrap(URL(string: "claudebar://settings"))))
    }

    func testMetricsCarryTheSpecResource() throws {
        let limit = UsageLimit(
            id: "credits:10080",
            name: "Weekly",
            percent: 42,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            windowDurationMinutes: 10_080
        )
        var tokens = TokenTypeCounts()
        tokens.input = 3
        tokens.reasoning = 1
        let scan = SessionScanState(
            cursors: [:],
            totals: ["grok-4.7": tokens],
            countingSince: Date(timeIntervalSince1970: 1_600_000_000)
        )
        let data = try OTLPTelemetryEncoder.metrics(
            limits: [limit],
            prepaidUSD: 12.5,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_100),
            serviceVersion: "0.1.0",
            tokens: scan
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resourceMetrics = try XCTUnwrap(object["resourceMetrics"] as? [[String: Any]])
        let resource = try XCTUnwrap(resourceMetrics.first?["resource"] as? [String: Any])
        let attributes = try XCTUnwrap(resource["attributes"] as? [[String: Any]])
        let values = Dictionary(uniqueKeysWithValues: attributes.compactMap { item -> (String, String)? in
            guard
                let key = item["key"] as? String,
                let value = item["value"] as? [String: Any],
                let string = value["stringValue"] as? String
            else { return nil }
            return (key, string)
        })
        XCTAssertEqual(values["service.name"], "grokbar")
        XCTAssertEqual(values["bar.spec.version"], "1")
        XCTAssertEqual(values["os.type"], "darwin")
        XCTAssertEqual(values["service.version"], "0.1.0")

        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(encoded.contains("bar.limit.utilization"))
        XCTAssertTrue(encoded.contains("bar.limit.resets_at"))
        XCTAssertTrue(encoded.contains("bar.tokens"))
        XCTAssertTrue(encoded.contains("grok.prepaid.balance"))
        XCTAssertTrue(encoded.contains("cache_write") == false)
        XCTAssertTrue(encoded.contains("\"token.type\""))
    }
}
