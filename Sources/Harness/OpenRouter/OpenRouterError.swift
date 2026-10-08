import Foundation
import FoundationModels

/// Failures only this provider can produce. Anything with a framework
/// equivalent is thrown as `LanguageModelError` instead.
public enum OpenRouterError: Error, Sendable, LocalizedError {
    case missingCredential(variable: String?)
    case http(status: Int, code: Int?, message: String)
    case streamFailed(message: String)
    case malformedEvent(String)
    case noOutput

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let variable):
            if let variable { return "No OpenRouter key found in environment variable \(variable)." }
            return "No OpenRouter key was provided."
        case .http(let status, let code, let message):
            return "OpenRouter returned HTTP \(status)\(code.map { " (code \($0))" } ?? ""): \(message)"
        case .streamFailed(let message):
            return "OpenRouter stream failed: \(message)"
        case .malformedEvent(let detail):
            return "Malformed stream event: \(detail)"
        case .noOutput:
            return "The response completed without any output items."
        }
    }
}

enum OpenRouterErrorMapping {
    /// Maps an HTTP error body to the framework's error vocabulary where one fits.
    static func error(status: Int, body: Data) -> any Error {
        var code: Int?
        var message = String(decoding: body, as: UTF8.self)
        if let json = try? JSONValue(data: body), let error = json["error"] {
            code = error["code"]?.intValue
            message = error["message"]?.stringValue ?? message
        }
        return classify(status: status, code: code, message: message)
    }

    static func classify(status: Int, code: Int?, message: String) -> any Error {
        let lowered = message.lowercased()
        let metadata: [String: any Sendable] = ["status": status, "message": message]
        switch status {
        case 429:
            return LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: message, metadata: metadata))
        case 408, 504:
            return LanguageModelError.timeout(.init(debugDescription: message, metadata: metadata))
        default:
            break
        }
        if lowered.contains("context length") || lowered.contains("context window") || lowered.contains("too many tokens")
            || lowered.contains("maximum context")
        {
            return LanguageModelError.contextSizeExceeded(.init(contextSize: 0, tokenCount: 0, debugDescription: message, metadata: metadata))
        }
        if lowered.contains("moderation") || lowered.contains("flagged") || lowered.contains("safety") {
            return LanguageModelError.guardrailViolation(.init(debugDescription: message, metadata: metadata))
        }
        return OpenRouterError.http(status: status, code: code, message: message)
    }
}
