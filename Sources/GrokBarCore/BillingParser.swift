import Foundation

public struct RPCError: Decodable, Error, Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public enum BillingProtocolError: Error, LocalizedError, Equatable {
    case malformedResponse
    case missingBilling
    case requestFailed(RPCError)

    public var errorDescription: String? {
        switch self {
        case .malformedResponse:
            return "Grok returned a malformed response"
        case .missingBilling:
            return "Grok didn't return billing information"
        case let .requestFailed(error):
            if error.message.localizedCaseInsensitiveContains("grok login")
                || error.message.localizedCaseInsensitiveContains("authentication required") {
                return "Sign in with grok login"
            }
            return error.message
        }
    }
}

public struct BillingProbe: Sendable, Equatable {
    public let billing: BillingConfigResponse?
    public let error: RPCError?

    public init(billing: BillingConfigResponse?, error: RPCError?) {
        self.billing = billing
        self.error = error
    }
}

public enum BillingResponseParser {
    /// Reads newline-delimited JSON-RPC. The billing result is the message whose id is 1.
    public static func parse(_ data: Data) throws -> BillingProbe {
        let decoder = JSONDecoder()
        var sawJSON = false
        var billing: BillingConfigResponse?
        var error: RPCError?

        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let header = try? decoder.decode(ResponseHeader.self, from: Data(line)) else { continue }
            sawJSON = true
            guard header.id == 1 else { continue }
            if let headerError = header.error {
                error = headerError
            } else if let response = try? decoder.decode(BillingResponse.self, from: Data(line)) {
                billing = response.result
            } else {
                throw BillingProtocolError.malformedResponse
            }
        }

        guard sawJSON else { throw BillingProtocolError.malformedResponse }
        if let error { throw BillingProtocolError.requestFailed(error) }
        guard billing != nil else { throw BillingProtocolError.missingBilling }
        return BillingProbe(billing: billing, error: nil)
    }

    private struct ResponseHeader: Decodable {
        let id: Int?
        let error: RPCError?
    }

    private struct BillingResponse: Decodable {
        let result: BillingConfigResponse
    }
}
