import Foundation

public enum OTLPTelemetryEncoder {
    struct Attribute: Encodable, Sendable {
        let key: String
        let value: Value

        init(_ key: String, _ value: String) { self.key = key; self.value = Value(stringValue: value) }
        init(_ key: String, _ value: Bool) { self.key = key; self.value = Value(boolValue: value) }
        init(_ key: String, _ value: Int) { self.key = key; self.value = Value(intValue: String(value)) }
        init(_ key: String, _ value: Double) { self.key = key; self.value = Value(doubleValue: value) }
    }

    struct Value: Encodable, Sendable {
        var stringValue: String?
        var boolValue: Bool?
        var intValue: String?
        var doubleValue: Double?
    }

    private struct Resource: Encodable { let attributes: [Attribute] }
    private struct Scope: Encodable {
        let name = "com.gordonbeeming.GrokBar.telemetry"
        let version: String
    }
    private struct Point: Encodable {
        let attributes: [Attribute]
        var startTimeUnixNano: String? = nil
        let timeUnixNano: String
        let asDouble: Double?
        let asInt: String?
    }
    private struct Gauge: Encodable { let dataPoints: [Point] }
    private struct Sum: Encodable {
        let dataPoints: [Point]
        let aggregationTemporality = 2
        let isMonotonic = true
    }
    private struct Metric: Encodable {
        let name: String
        let unit: String
        var gauge: Gauge?
        var sum: Sum?
    }
    private struct ScopeMetrics: Encodable { let scope: Scope; let metrics: [Metric] }
    private struct ResourceMetrics: Encodable { let resource: Resource; let scopeMetrics: [ScopeMetrics] }
    private struct MetricsData: Encodable { let resourceMetrics: [ResourceMetrics] }

    struct Event: Sendable {
        let name: String
        let attributes: [Attribute]
    }
    private struct LogRecord: Encodable {
        let timeUnixNano: String
        let observedTimeUnixNano: String
        let severityNumber = 9
        let severityText = "INFO"
        let eventName: String
        let attributes: [Attribute]
    }
    private struct ScopeLogs: Encodable { let scope: Scope; let logRecords: [LogRecord] }
    private struct ResourceLogs: Encodable { let resource: Resource; let scopeLogs: [ScopeLogs] }
    private struct LogsData: Encodable { let resourceLogs: [ResourceLogs] }

    public static func metrics(
        limits: [UsageLimit],
        prepaidUSD: Double?,
        capturedAt: Date,
        serviceVersion: String,
        tokens: SessionScanState? = nil
    ) throws -> Data {
        let timestamp = try nanos(capturedAt)
        let barLimits = BarLimit.limits(from: limits)
        var metrics: [Metric] = []
        let utilization = barLimits.map {
            Point(attributes: $0.attributes, timeUnixNano: timestamp, asDouble: $0.utilization, asInt: nil)
        }
        let resetsAt = barLimits.compactMap { limit in
            limit.resetsAt.map {
                Point(attributes: limit.attributes, timeUnixNano: timestamp, asDouble: nil, asInt: String(Int64($0)))
            }
        }
        if !utilization.isEmpty {
            metrics.append(Metric(name: "bar.limit.utilization", unit: "%", gauge: Gauge(dataPoints: utilization)))
        }
        if !resetsAt.isEmpty {
            metrics.append(Metric(name: "bar.limit.resets_at", unit: "s", gauge: Gauge(dataPoints: resetsAt)))
        }
        if let prepaidUSD, prepaidUSD.isFinite, prepaidUSD >= 0 {
            metrics.append(Metric(
                name: "grok.prepaid.balance",
                unit: "USD",
                gauge: Gauge(dataPoints: [
                    Point(attributes: [], timeUnixNano: timestamp, asDouble: prepaidUSD, asInt: nil)
                ])
            ))
        }
        if let tokens, !tokens.totals.isEmpty {
            let start = try nanos(tokens.countingSince)
            let points = tokens.totals.keys.sorted().flatMap { model -> [Point] in
                guard let counts = tokens.totals[model] else { return [] }
                let byType: [(String, Int64)] = [
                    ("input", counts.input), ("cache_read", counts.cacheRead), ("cache_write", counts.cacheWrite),
                    ("output", counts.output), ("reasoning", counts.reasoning)
                ]
                return byType.compactMap { type, value in
                    guard value > 0 else { return nil }
                    return Point(
                        attributes: [.init("model", model), .init("token.type", type)],
                        startTimeUnixNano: start,
                        timeUnixNano: timestamp,
                        asDouble: nil,
                        asInt: String(value)
                    )
                }
            }
            if !points.isEmpty {
                metrics.append(Metric(name: "bar.tokens", unit: "{token}", sum: Sum(dataPoints: points)))
            }
        }
        return try encode(MetricsData(resourceMetrics: [ResourceMetrics(
            resource: resource(serviceVersion),
            scopeMetrics: [ScopeMetrics(scope: Scope(version: serviceVersion), metrics: metrics)]
        )]))
    }

    static func logs(_ events: [Event], at date: Date, serviceVersion: String) throws -> Data {
        let timestamp = try nanos(date)
        let records = events.map {
            LogRecord(timeUnixNano: timestamp, observedTimeUnixNano: timestamp, eventName: $0.name, attributes: $0.attributes)
        }
        return try encode(LogsData(resourceLogs: [ResourceLogs(
            resource: resource(serviceVersion),
            scopeLogs: [ScopeLogs(scope: Scope(version: serviceVersion), logRecords: records)]
        )]))
    }

    private static let hostName = ProcessInfo.processInfo.hostName

    private static func resource(_ version: String) -> Resource {
        Resource(attributes: [
            Attribute("service.name", "grokbar"),
            Attribute("service.version", version),
            Attribute("host.name", hostName),
            Attribute("os.type", "darwin"),
            Attribute("bar.spec.version", barSpecVersion)
        ])
    }

    private static func nanos(_ date: Date) throws -> String {
        let value = date.timeIntervalSince1970 * 1_000_000_000
        guard value.isFinite, value >= 0, value < Double(UInt64.max) else {
            throw CocoaError(.coderInvalidValue)
        }
        return String(UInt64(value))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
