import Foundation
import XCTest
@testable import GrokBarCore

final class BillingTests: XCTestCase {
    func testWeeklyCreditsOnDemandAndPrepaid() throws {
        let response = try decode("""
        {
          "config": {
            "creditUsagePercent": 42.5,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-06-01T00:00:00Z",
              "end": "2026-06-08T00:00:00Z"
            },
            "onDemandCap": {"val": 5000},
            "onDemandUsed": {"val": 1000},
            "prepaidBalance": {"val": 1250},
            "productUsage": [
              {"product": "PRODUCT_GROK_BUILD", "usagePercent": 61.2}
            ]
          },
          "subscriptionTier": "SuperGrok"
        }
        """)

        let limits = UsageLimitMapper.limits(from: response)
        XCTAssertEqual(limits.map(\.id), ["credits:10080", "on_demand", "product:PRODUCT_GROK_BUILD"])
        XCTAssertEqual(limits.map(\.name), ["Weekly", "On-demand", "Grok Build"])
        XCTAssertEqual(limits[0].percent, 42.5)
        XCTAssertEqual(limits[0].group, "weekly")
        XCTAssertEqual(limits[1].percent, 20)
        XCTAssertEqual(limits[2].percent, 61.2)
        XCTAssertEqual(limits[0].windowDurationMinutes, 10_080)
        XCTAssertEqual(UsageLimitMapper.planType(from: response), "SuperGrok")
        XCTAssertEqual(UsageLimitMapper.prepaidUSD(from: response), 12.5)
    }

    func testSnakeCaseSubscriptionTierFromCLI() throws {
        let response = try decode("""
        {
          "config": {
            "creditUsagePercent": 56,
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-11-02T02:16:13.559+00:00",
              "end": "2026-11-09T02:16:13.559+00:00"
            },
            "prepaidBalance": {"val": 0}
          },
          "subscription_tier": "SuperGrok Heavy"
        }
        """)
        let limits = UsageLimitMapper.limits(from: response)
        XCTAssertEqual(limits.map(\.id), ["credits:10080"])
        XCTAssertEqual(limits.map(\.name), ["Weekly"])
        XCTAssertEqual(limits[0].percent, 56)
        XCTAssertEqual(UsageLimitMapper.planType(from: response), "SuperGrok Heavy")
        XCTAssertEqual(UsageLimitMapper.prepaidUSD(from: response), 0)
    }

    func testEmptyCentIsZeroAndLegacyMonthlyPercent() throws {
        let response = try decode("""
        {
          "config": {
            "monthlyLimit": {"val": 2000},
            "used": {"val": 500},
            "prepaidBalance": {},
            "billingPeriodStart": "2026-04-01T00:00:00Z",
            "billingPeriodEnd": "2026-05-01T00:00:00Z"
          }
        }
        """)
        let limits = UsageLimitMapper.limits(from: response)
        XCTAssertEqual(limits.map(\.id), ["credits:legacy"])
        XCTAssertEqual(limits[0].percent, 25)
        XCTAssertEqual(limits[0].group, "monthly")
        XCTAssertEqual(UsageLimitMapper.prepaidUSD(from: response), 0)
    }

    func testCalendarMonthsShareOneCreditID() throws {
        func month(_ start: String, _ end: String) throws -> UsageLimit {
            let response = try decode("""
            {
              "config": {
                "creditUsagePercent": 10,
                "currentPeriod": {"type": "USAGE_PERIOD_TYPE_MONTHLY", "start": "\(start)", "end": "\(end)"}
              }
            }
            """)
            return try XCTUnwrap(UsageLimitMapper.limits(from: response).first)
        }
        let june = try month("2026-06-01T00:00:00Z", "2026-07-01T00:00:00Z")
        let july = try month("2026-07-01T00:00:00Z", "2026-08-01T00:00:00Z")
        XCTAssertEqual(june.id, "credits:monthly")
        XCTAssertEqual(july.id, june.id)
        XCTAssertEqual(june.windowDurationMinutes, 30 * 24 * 60)
        XCTAssertEqual(july.windowDurationMinutes, 31 * 24 * 60)
        XCTAssertEqual(june.group, "monthly")
    }

    func testPercentClampsAndSkipsProductWithoutPercent() throws {
        let response = try decode("""
        {
          "config": {
            "creditUsagePercent": 140,
            "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY"},
            "productUsage": [{"product": "PRODUCT_API"}]
          }
        }
        """)
        let limits = UsageLimitMapper.limits(from: response)
        XCTAssertEqual(limits.map(\.id), ["credits:10080"])
        XCTAssertEqual(limits[0].percent, 100)
    }

    func testAuthErrorBecomesSignInMessage() {
        let line = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Authentication required to fetch billing data. Run 'grok login' to authenticate."}}"#
        XCTAssertThrowsError(try BillingResponseParser.parse(Data(line.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "Sign in with grok login")
        }
    }

    func testParsesBillingResultAndIgnoresInitialize() throws {
        let payload = """
        {"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"1"}}
        {"jsonrpc":"2.0","id":1,"result":{"config":{"creditUsagePercent":10,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-01T00:00:00Z","end":"2026-06-08T00:00:00Z"}}}}
        """
        let probe = try BillingResponseParser.parse(Data(payload.utf8))
        let limits = try XCTUnwrap(probe.billing).config
        XCTAssertEqual(limits?.creditUsagePercent, 10)
    }

    private func decode(_ json: String) throws -> BillingConfigResponse {
        try JSONDecoder().decode(BillingConfigResponse.self, from: Data(json.utf8))
    }
}
