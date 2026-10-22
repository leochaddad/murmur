import Foundation

enum OpenAIError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case insufficientQuota
    case rateLimited
    case modelNotFound(String)
    case badRequest(message: String, param: String?)
    case server(status: Int, message: String)
    case network(String)
    case timedOut
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your OpenAI API key in Murmur Settings."
        case .invalidAPIKey: "OpenAI rejected the API key. Check it in Murmur Settings."
        case .insufficientQuota: "Your OpenAI account is out of credits or over its usage limit."
        case .rateLimited: "OpenAI is rate-limiting requests. Try again in a moment."
        case .modelNotFound(let model): "The model “\(model)” isn’t available to your OpenAI account."
        case .badRequest(let message, _): "OpenAI couldn’t process the request: \(message)"
        case .server(let status, _): "OpenAI had a server problem (\(status)). Try again."
        case .network(let message): "Network problem: \(message)"
        case .timedOut: "The request to OpenAI timed out."
        case .invalidResponse: "OpenAI returned an unexpected response."
        }
    }

    /// Short form for the HUD.
    var shortDescription: String {
        switch self {
        case .missingAPIKey: "No OpenAI API key"
        case .invalidAPIKey: "Invalid OpenAI API key"
        case .insufficientQuota: "OpenAI quota exceeded"
        case .rateLimited: "Rate limited by OpenAI"
        case .modelNotFound: "Model not available"
        case .badRequest: "Request rejected by OpenAI"
        case .server: "OpenAI server error"
        case .network: "No connection to OpenAI"
        case .timedOut: "OpenAI timed out"
        case .invalidResponse: "Unexpected OpenAI response"
        }
    }

    /// Errors worth retrying automatically.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .server, .network, .timedOut: true
        default: false
        }
    }

    static func from(status: Int, body: Data) -> OpenAIError {
        let detail = try? JSONDecoder().decode(ErrorEnvelope.self, from: body).error
        let message = detail?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 401: return .invalidAPIKey
        case 429: return detail?.code == "insufficient_quota" ? .insufficientQuota : .rateLimited
        case 404 where detail?.code == "model_not_found": return .modelNotFound(detail?.param ?? "")
        case 400..<500:
            if detail?.code == "model_not_found" { return .modelNotFound(detail?.param ?? "") }
            return .badRequest(message: message, param: detail?.param)
        default: return .server(status: status, message: message)
        }
    }

    static func from(urlError: URLError) -> OpenAIError {
        urlError.code == .timedOut ? .timedOut : .network(urlError.localizedDescription)
    }

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let message: String?
            let type: String?
            let code: String?
            let param: String?
        }
        let error: Detail
    }
}
