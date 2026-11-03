import Foundation

public enum Severity: Int, Sendable, Comparable {
    case normal
    case warning
    case critical

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct UsageLimit: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let percent: Double
    public let resetsAt: Date?
    public let windowDurationMinutes: Int?

    public init(
        id: String,
        name: String,
        percent: Double,
        resetsAt: Date?,
        windowDurationMinutes: Int?
    ) {
        self.id = id
        self.name = name
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowDurationMinutes = windowDurationMinutes
    }

    public var defaultSeverity: Severity {
        if percent >= 90 { return .critical }
        if percent >= 75 { return .warning }
        return .normal
    }

    public var group: String? {
        switch windowDurationMinutes {
        case 300: return "session"
        case let minutes? where (4 * 24 * 60)...(12 * 24 * 60) ~= minutes: return "weekly"
        case let minutes? where (20 * 24 * 60)...(45 * 24 * 60) ~= minutes: return "monthly"
        default: return nil
        }
    }

    public var celebrationKey: String { id }
}

public func highestLimit(in limits: [UsageLimit]) -> UsageLimit? {
    limits.max { $0.percent < $1.percent }
}

public func menuBarLimit(in limits: [UsageLimit], selectedID: String?) -> UsageLimit? {
    guard let selectedID else { return highestLimit(in: limits) }
    return limits.first { $0.id == selectedID } ?? highestLimit(in: limits)
}

public enum UsageWindow {
    public static func paceFraction(for limit: UsageLimit, now: Date = Date()) -> Double? {
        guard
            let resetsAt = limit.resetsAt,
            let durationMinutes = limit.windowDurationMinutes,
            durationMinutes > 0
        else { return nil }

        let duration = TimeInterval(durationMinutes * 60)
        let startedAt = resetsAt.addingTimeInterval(-duration)
        return min(max(now.timeIntervalSince(startedAt) / duration, 0), 1)
    }

    public static func isAheadOfPace(
        for limit: UsageLimit,
        now: Date = Date(),
        marginPercent: Double = 0
    ) -> Bool {
        guard limit.percent > 5 else { return false }
        guard let pace = paceFraction(for: limit, now: now) else { return false }
        return limit.percent - pace * 100 > marginPercent + 0.0001
    }
}

/// USD cents. proto3 JSON omits a zero `val`, so `{}` is zero cents.
public struct CentValue: Decodable, Sendable, Equatable {
    public var val: Int64

    public init(val: Int64) { self.val = val }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        val = try container.decodeIfPresent(Int64.self, forKey: .val) ?? 0
    }

    private enum CodingKeys: String, CodingKey { case val }

    public var usd: Double { Double(val) / 100 }
}

public struct BillingPeriod: Decodable, Sendable, Equatable {
    public var type: String?
    public var start: String?
    public var end: String?

    public init(type: String? = nil, start: String? = nil, end: String? = nil) {
        self.type = type
        self.start = start
        self.end = end
    }
}

public struct ProductUsage: Decodable, Sendable, Equatable {
    public var product: String
    public var usagePercent: Double?

    public init(product: String, usagePercent: Double?) {
        self.product = product
        self.usagePercent = usagePercent
    }
}

public struct BillingConfig: Decodable, Sendable, Equatable {
    public var creditUsagePercent: Double?
    public var currentPeriod: BillingPeriod?
    public var monthlyLimit: CentValue?
    public var used: CentValue?
    public var onDemandCap: CentValue?
    public var onDemandUsed: CentValue?
    public var prepaidBalance: CentValue?
    public var billingPeriodStart: String?
    public var billingPeriodEnd: String?
    public var productUsage: [ProductUsage]?

    public init(
        creditUsagePercent: Double? = nil,
        currentPeriod: BillingPeriod? = nil,
        monthlyLimit: CentValue? = nil,
        used: CentValue? = nil,
        onDemandCap: CentValue? = nil,
        onDemandUsed: CentValue? = nil,
        prepaidBalance: CentValue? = nil,
        billingPeriodStart: String? = nil,
        billingPeriodEnd: String? = nil,
        productUsage: [ProductUsage]? = nil
    ) {
        self.creditUsagePercent = creditUsagePercent
        self.currentPeriod = currentPeriod
        self.monthlyLimit = monthlyLimit
        self.used = used
        self.onDemandCap = onDemandCap
        self.onDemandUsed = onDemandUsed
        self.prepaidBalance = prepaidBalance
        self.billingPeriodStart = billingPeriodStart
        self.billingPeriodEnd = billingPeriodEnd
        self.productUsage = productUsage
    }
}

public struct BillingConfigResponse: Decodable, Sendable, Equatable {
    public var config: BillingConfig?
    public var subscriptionTier: String?

    public init(config: BillingConfig?, subscriptionTier: String? = nil) {
        self.config = config
        self.subscriptionTier = subscriptionTier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        config = try container.decodeIfPresent(BillingConfig.self, forKey: .config)
        // The CLI's billing wrapper uses serde snake_case. Config fields stay camelCase
        // because they come from the protobuf JSON. Accept either key so a fixture and
        // a live `grok` 1.0.x response both yield a plan name.
        if let tier = try container.decodeIfPresent(String.self, forKey: .subscriptionTier), !tier.isEmpty {
            subscriptionTier = tier
        } else {
            subscriptionTier = try container.decodeIfPresent(String.self, forKey: .subscriptionTierSnake)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case config
        case subscriptionTier
        case subscriptionTierSnake = "subscription_tier"
    }
}

public enum UsageLimitMapper {
    public static func limits(from response: BillingConfigResponse, now: Date = Date()) -> [UsageLimit] {
        guard let config = response.config else { return [] }
        let period = resolvedPeriod(config)
        var limits: [UsageLimit] = []

        if let percent = config.creditUsagePercent, percent.isFinite {
            limits.append(makeLimit(
                id: creditID(period: period),
                name: creditName(period: period),
                percent: percent,
                period: period
            ))
        } else if let limit = config.monthlyLimit?.val, limit > 0, let used = config.used?.val {
            let percent = Double(used) / Double(limit) * 100
            limits.append(makeLimit(
                id: "credits:legacy",
                name: creditName(period: period),
                percent: percent,
                period: period
            ))
        }

        if let cap = config.onDemandCap?.val, cap > 0 {
            let used = config.onDemandUsed?.val ?? 0
            limits.append(makeLimit(
                id: "on_demand",
                name: "On-demand",
                percent: Double(used) / Double(cap) * 100,
                period: period
            ))
        }

        for product in config.productUsage ?? [] {
            guard let percent = product.usagePercent, percent.isFinite, !product.product.isEmpty else { continue }
            limits.append(makeLimit(
                id: "product:\(product.product)",
                name: humanize(product.product),
                percent: percent,
                period: period
            ))
        }

        return limits
    }

    public static func prepaidUSD(from response: BillingConfigResponse) -> Double? {
        response.config?.prepaidBalance?.usd
    }

    public static func planType(from response: BillingConfigResponse) -> String? {
        response.subscriptionTier.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func resolvedPeriod(_ config: BillingConfig) -> BillingPeriod {
        if let current = config.currentPeriod, current.start != nil || current.end != nil || current.type != nil {
            return current
        }
        return BillingPeriod(type: nil, start: config.billingPeriodStart, end: config.billingPeriodEnd)
    }

    private static func makeLimit(id: String, name: String, percent: Double, period: BillingPeriod) -> UsageLimit {
        let bounds = window(period)
        return UsageLimit(
            id: id,
            name: name,
            percent: min(max(percent, 0), 100),
            resetsAt: bounds.end,
            windowDurationMinutes: bounds.minutes
        )
    }

    private static func window(_ period: BillingPeriod) -> (end: Date?, minutes: Int?) {
        let start = period.start.flatMap(parseDate)
        let end = period.end.flatMap(parseDate)
        if let start, let end, end > start {
            let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
            return (end, minutes > 0 ? minutes : nil)
        }
        if period.type?.contains("WEEKLY") == true {
            return (end, 10_080)
        }
        if period.type?.contains("MONTHLY") == true {
            return (end, 43_200)
        }
        return (end, nil)
    }

    private static func creditID(period: BillingPeriod) -> String {
        let bounds = window(period)
        if let minutes = bounds.minutes {
            // A calendar month is 28 to 31 days, so the minute count is not a stable identity.
            // The real length stays on windowDurationMinutes.
            if (20 * 24 * 60)...(45 * 24 * 60) ~= minutes { return "credits:monthly" }
            return "credits:\(minutes)"
        }
        if period.type?.contains("WEEKLY") == true { return "credits:weekly" }
        if period.type?.contains("MONTHLY") == true { return "credits:monthly" }
        return "credits"
    }

    private static func creditName(period: BillingPeriod) -> String {
        let bounds = window(period)
        if let minutes = bounds.minutes {
            if (4 * 24 * 60)...(12 * 24 * 60) ~= minutes { return "Weekly" }
            if (20 * 24 * 60)...(45 * 24 * 60) ~= minutes { return "Monthly" }
        }
        if period.type?.contains("WEEKLY") == true { return "Weekly" }
        if period.type?.contains("MONTHLY") == true { return "Monthly" }
        return "Credits"
    }

    static func humanize(_ value: String) -> String {
        var text = value
        if text.hasPrefix("PRODUCT_") { text.removeFirst("PRODUCT_".count) }
        return text
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
