import Foundation

public let barSpecVersion = "1"

struct BarLimit: Sendable, Equatable {
    let id: String
    let name: String
    let windowMinutes: Int?
    let utilization: Double
    let resetsAt: TimeInterval?

    var attributes: [OTLPTelemetryEncoder.Attribute] {
        var attributes: [OTLPTelemetryEncoder.Attribute] = [.init("limit.id", id), .init("limit.name", name)]
        if let windowMinutes { attributes.append(.init("limit.window.duration_minutes", windowMinutes)) }
        return attributes
    }

    static func limits(from usage: [UsageLimit]) -> [BarLimit] {
        usage.filter { $0.percent.isFinite }.map {
            BarLimit(
                id: $0.id,
                name: $0.name,
                windowMinutes: $0.windowDurationMinutes,
                utilization: min(max($0.percent, 0), 100),
                resetsAt: $0.resetsAt?.timeIntervalSince1970
            )
        }
    }
}

struct ObservedLimit: Codable, Sendable, Equatable {
    var name: String
    var windowMinutes: Int?
    var utilization: Double
    var resetsAt: TimeInterval?
}

enum BarEvents {
    static func trackingStarted(intervalMinutes: Int) -> OTLPTelemetryEncoder.Event {
        .init(name: "bar.tracking.started", attributes: [.init("tracking.interval_minutes", intervalMinutes)])
    }

    static func observed(_ limits: [BarLimit]) -> [String: ObservedLimit] {
        Dictionary(limits.map {
            ($0.id, ObservedLimit(name: $0.name, windowMinutes: $0.windowMinutes, utilization: $0.utilization, resetsAt: $0.resetsAt))
        }, uniquingKeysWith: { first, _ in first })
    }

    static func limitEvents(previous: [String: ObservedLimit]?, current: [BarLimit], now: Date) -> [OTLPTelemetryEncoder.Event] {
        let previous = previous ?? [:]
        var events: [OTLPTelemetryEncoder.Event] = []
        for limit in current {
            guard let before = previous[limit.id] else {
                events.append(.init(name: "bar.limit.appeared", attributes: limit.attributes))
                continue
            }
            if didReset(from: before, to: limit, now: now) {
                var attributes = limit.attributes + [.init("limit.utilization.last", before.utilization)]
                if let next = limit.resetsAt { attributes.append(.init("limit.resets_at.next", Int(next))) }
                events.append(.init(name: "bar.limit.reset", attributes: attributes))
            }
        }
        let currentIDs = Set(current.map(\.id))
        for (id, before) in previous.sorted(by: { $0.key < $1.key }) where !currentIDs.contains(id) {
            var attributes: [OTLPTelemetryEncoder.Attribute] = [.init("limit.id", id), .init("limit.name", before.name)]
            if let minutes = before.windowMinutes { attributes.append(.init("limit.window.duration_minutes", minutes)) }
            events.append(.init(name: "bar.limit.disappeared", attributes: attributes))
        }
        return events
    }

    static let resetJumpTolerance: TimeInterval = 3_600

    static func didReset(from before: ObservedLimit, to limit: BarLimit, now: Date) -> Bool {
        guard let old = before.resetsAt, let new = limit.resetsAt else {
            return usageDidReset(from: before.utilization, to: limit.utilization)
        }
        let jump = new - old
        // Half a window, in seconds: minutes * 60 / 2. A window that rolls while usage stays at 0% is still a reset.
        if let minutes = limit.windowMinutes, jump >= Double(minutes) * 30 { return true }
        if limit.windowMinutes == nil, jump >= resetJumpTolerance { return true }
        guard jump > resetJumpTolerance else { return false }
        if usageDidReset(from: before.utilization, to: limit.utilization) { return true }
        guard let minutes = limit.windowMinutes, limit.utilization < before.utilization else { return false }
        let window = Double(minutes) * 60
        return abs(new - now.timeIntervalSince1970 - window) <= resetJumpTolerance
    }
}
