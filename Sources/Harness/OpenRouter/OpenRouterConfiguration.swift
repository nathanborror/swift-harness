import Foundation
import Security

/// Where an OpenRouter executor sends requests and how it authenticates.
///
/// The framework keys its executor cache on this value, so two models with the
/// same configuration share one executor and one `URLSession`. The model ID is
/// deliberately not part of it: switching models inside a dynamic profile then
/// keeps the connection and any provider-side cache.
public struct OpenRouterConfiguration: Hashable, Sendable {
    /// How the executor obtains the bearer token for each request.
    public enum Credential: Hashable, Sendable {
        /// Read the key from the process environment at request time.
        case environment(variable: String = "OPENROUTER_API_KEY")
        /// Use a literal key. Fine for development, never for a shipped app.
        case apiKey(String)
        /// Read a generic-password Keychain item at request time, so a key
        /// rotated in the app's settings takes effect on the next call. A
        /// missing item fails the request with `missingCredential`.
        case keychain(service: String, account: String)
        /// Send no bearer token. Use with a proxy at `baseURL` that attaches the real key.
        case none
    }

    public var baseURL: URL
    public var credential: Credential
    /// Extra headers sent on every request. OpenRouter reads `HTTP-Referer` and
    /// `X-Title` for app attribution, and a proxy can read whatever it needs.
    public var additionalHeaders: [String: String]
    /// Per-request timeout. Long agent turns can run for minutes, so the default is generous.
    public var timeout: TimeInterval
    public var retry: RetryPolicy
    /// When set, every request body and raw response is written here, one pair
    /// of files per attempt, for diagnosing cache misses and rejected fields.
    public var debugDirectory: URL?

    /// How transient failures are retried. A retry happens only before any
    /// output has reached the session; a stream that fails part way is an error.
    public struct RetryPolicy: Hashable, Sendable {
        /// Total attempts, including the first.
        public var maximumAttempts: Int
        /// Delay before the second attempt, doubled each time after, unless the server says otherwise.
        public var baseDelay: TimeInterval
        public var maximumDelay: TimeInterval

        public init(maximumAttempts: Int = 2, baseDelay: TimeInterval = 1, maximumDelay: TimeInterval = 30) {
            self.maximumAttempts = maximumAttempts
            self.baseDelay = baseDelay
            self.maximumDelay = maximumDelay
        }

        public static let none = RetryPolicy(maximumAttempts: 1)
    }

    public init(
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        credential: Credential = .environment(),
        additionalHeaders: [String: String] = [:],
        timeout: TimeInterval = 600,
        retry: RetryPolicy = RetryPolicy(),
        debugDirectory: URL? = nil
    ) {
        self.baseURL = baseURL
        self.credential = credential
        self.additionalHeaders = additionalHeaders
        self.timeout = timeout
        self.retry = retry
        self.debugDirectory = debugDirectory
    }

    func resolveBearerToken() throws -> String? {
        switch credential {
        case .environment(let variable):
            guard let key = ProcessInfo.processInfo.environment[variable], !key.isEmpty else {
                throw OpenRouterError.missingCredential(variable: variable)
            }
            return key
        case .apiKey(let key):
            guard !key.isEmpty else { throw OpenRouterError.missingCredential(variable: nil) }
            return key
        case .keychain(let service, let account):
            guard let key = Self.keychainItem(service: service, account: account), !key.isEmpty else {
                throw OpenRouterError.missingCredential(variable: nil)
            }
            return key
        case .none:
            return nil
        }
    }

    /// The UTF-8 value of a generic-password item, or nil when there is none.
    static func keychainItem(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
