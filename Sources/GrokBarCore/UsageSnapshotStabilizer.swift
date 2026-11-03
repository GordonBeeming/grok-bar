import Foundation

public struct UsageSnapshotStabilizer: Sendable {
    public enum Decision: Sendable, Equatable {
        case accepted([UsageLimit])
        case acceptedPlanChange([UsageLimit])
        case held(confirmations: Int, required: Int)
    }

    private struct PendingRegression: Sendable {
        var limits: [UsageLimit]
        var regressedIDs: Set<String>
        var confirmations: Int
    }

    private let requiredConsecutiveSamples: Int
    private let suspiciousDropPercent: Double
    private var trustedLimits: [UsageLimit]?
    private var trustedPlanType: String?
    private var pendingRegression: PendingRegression?

    public init(requiredConsecutiveSamples: Int = 3, suspiciousDropPercent: Double = 10) {
        self.requiredConsecutiveSamples = max(requiredConsecutiveSamples, 2)
        self.suspiciousDropPercent = max(suspiciousDropPercent, 1)
    }

    public mutating func evaluate(_ candidate: [UsageLimit], planType: String? = nil) -> Decision {
        if
            let trustedPlanType,
            let planType,
            trustedPlanType.caseInsensitiveCompare(planType) != .orderedSame
        {
            self.trustedPlanType = planType
            trustedLimits = candidate
            pendingRegression = nil
            return .acceptedPlanChange(candidate)
        }

        if trustedPlanType == nil {
            trustedPlanType = planType
        }

        guard let trustedLimits else {
            self.trustedLimits = candidate
            return .accepted(candidate)
        }

        guard isSuspiciousRegression(candidate, comparedWith: trustedLimits) else {
            self.trustedLimits = candidate
            pendingRegression = nil
            return .accepted(candidate)
        }

        let regressedIDs = regressedIDs(candidate, comparedWith: trustedLimits)
        if var pendingRegression,
           pendingRegression.regressedIDs == regressedIDs,
           hasSameWindows(candidate, as: pendingRegression.limits) {
            pendingRegression.limits = candidate
            pendingRegression.confirmations += 1

            if pendingRegression.confirmations >= requiredConsecutiveSamples {
                self.trustedLimits = candidate
                self.pendingRegression = nil
                return .accepted(candidate)
            }

            self.pendingRegression = pendingRegression
            return .held(
                confirmations: pendingRegression.confirmations,
                required: requiredConsecutiveSamples
            )
        }

        pendingRegression = PendingRegression(limits: candidate, regressedIDs: regressedIDs, confirmations: 1)
        return .held(confirmations: 1, required: requiredConsecutiveSamples)
    }

    private func isSuspiciousRegression(
        _ candidate: [UsageLimit],
        comparedWith trusted: [UsageLimit]
    ) -> Bool {
        !regressedIDs(candidate, comparedWith: trusted).isEmpty
    }

    /// Limits whose drop is large enough to quarantine. A later sample only continues the count when this set is unchanged.
    private func regressedIDs(
        _ candidate: [UsageLimit],
        comparedWith trusted: [UsageLimit]
    ) -> Set<String> {
        let trustedByID = Dictionary(
            trusted.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var ids = Set<String>()
        for current in candidate {
            guard let previous = trustedByID[current.id] else { continue }
            let drop = previous.percent - current.percent
            guard drop >= suspiciousDropPercent else { continue }
            if !hasConvincingResetAdvance(from: previous, to: current) {
                ids.insert(current.id)
            }
        }
        return ids
    }

    private func hasConvincingResetAdvance(from previous: UsageLimit, to current: UsageLimit) -> Bool {
        guard
            let previousReset = previous.resetsAt,
            let currentReset = current.resetsAt,
            let durationMinutes = current.windowDurationMinutes,
            durationMinutes > 0
        else {
            return false
        }

        let windowDuration = TimeInterval(durationMinutes * 60)
        return currentReset.timeIntervalSince(previousReset) >= windowDuration * 0.5
    }

    private func hasSameWindows(_ lhs: [UsageLimit], as rhs: [UsageLimit]) -> Bool {
        let rhsByID = Dictionary(
            rhs.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        guard Set(lhs.map(\.id)) == Set(rhsByID.keys) else { return false }

        return lhs.allSatisfy { current in
            guard let previous = rhsByID[current.id] else { return false }
            switch (current.resetsAt, previous.resetsAt) {
            case let (currentReset?, previousReset?):
                return abs(currentReset.timeIntervalSince(previousReset)) <= 300
            case (nil, nil):
                return true
            default:
                return false
            }
        }
    }
}
