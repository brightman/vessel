import Foundation
import CryptoKit
import Security

struct ChatGPTModel: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
}

struct ChatGPTCredential: Codable, Equatable {
    let clientID: String
    let subject: String
    let email: String?
    let hostID: String
    let idToken: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let scopes: Set<String>

    var canUsePlan: Bool { scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke") }
}

enum ChatGPTError: Error, Equatable, LocalizedError {
    case unavailableConfiguration, cancelled, invalidCallback, invalidIdentity, permissionMissing
    case expired, usageLimit, notEligible, temporarilyUnavailable, network, invalidResponse
    case incompleteResponse, storage
    case http(status: Int, code: String?, requestID: String?)

    var errorDescription: String? {
        switch self {
        case .unavailableConfiguration: return NSLocalizedString("此版本尚未启用 ChatGPT 登录。", comment: "")
        case .cancelled: return NSLocalizedString("已取消 ChatGPT 登录。", comment: "")
        case .invalidCallback: return NSLocalizedString("无法验证 ChatGPT 登录回调，请重新登录。", comment: "")
        case .invalidIdentity: return NSLocalizedString("无法验证 ChatGPT 账号身份，请重新登录。", comment: "")
        case .permissionMissing: return NSLocalizedString("请检查 ChatGPT 账号与套餐使用权限。", comment: "")
        case .expired: return NSLocalizedString("ChatGPT 登录已失效，请重新登录。", comment: "")
        case .usageLimit: return NSLocalizedString("已达到 ChatGPT 应用用量上限，请前往 ChatGPT 设置中的用量页面查看。", comment: "")
        case .notEligible: return NSLocalizedString("此账号或工作区暂时无法使用 ChatGPT 套餐。", comment: "")
        case .temporarilyUnavailable: return NSLocalizedString("ChatGPT 暂时不可用，请稍后重试。", comment: "")
        case .network: return NSLocalizedString("无法连接 ChatGPT，请检查网络后重试。", comment: "")
        case .invalidResponse: return NSLocalizedString("ChatGPT 返回了无效响应，请重试。", comment: "")
        case .incompleteResponse: return NSLocalizedString("ChatGPT 未完成回答，请重试。", comment: "")
        case .storage: return NSLocalizedString("无法安全保存 ChatGPT 账号，请重试。", comment: "")
        case let .http(status, code, requestID):
            return String(format: NSLocalizedString("ChatGPT 请求失败（HTTP %lld）。", comment: ""), Int64(status)) + (code.map { " [\($0)]" } ?? "") + (requestID.map { " [\($0)]" } ?? "")
        }
    }
}

struct ChatGPTAuthorizationAttempt {
    let callbackURL: URL
    let clientID: String?
    let hostID: String
    let state: String
    let nonce: String
    let verifier: String
    let idTokenHint: String?
    let loginHint: String?
    let expectedSubject: String?

    init(callbackURL: URL, clientID: String?, hostID: String, idTokenHint: String? = nil,
         loginHint: String? = nil, expectedSubject: String? = nil) throws {
        guard Self.validCallbackBase(callbackURL), Self.validIdentifier(hostID),
              clientID.map({ Self.validIdentifier($0) && $0 != "dynamic_agent_client" }) ?? true,
              clientID != nil || (idTokenHint == nil && loginHint == nil && expectedSubject == nil)
        else { throw ChatGPTError.invalidCallback }
        self.callbackURL = callbackURL
        self.clientID = clientID
        self.hostID = hostID
        self.idTokenHint = idTokenHint
        self.loginHint = loginHint
        self.expectedSubject = expectedSubject
        state = try Self.secret()
        nonce = try Self.secret()
        verifier = try Self.secret()
    }

    static func validCallbackBase(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return c.scheme == "http" && c.host == "127.0.0.1" && c.port.map({ (1...65535).contains($0) }) == true &&
            c.percentEncodedPath == "/auth/callback" && c.user == nil && c.password == nil && c.query == nil && c.fragment == nil
    }
    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) })
    }
    private static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatGPTError.invalidIdentity }
        return Data(bytes).chatGPTBase64URL
    }
}

extension Data {
    var chatGPTBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(chatGPTBase64URL string: String) {
        guard !string.isEmpty, string.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), string.utf8.count % 4 != 1 else { return nil }
        let padded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - string.utf8.count % 4) % 4)
        guard let decoded = Data(base64Encoded: padded), decoded.chatGPTBase64URL == string else { return nil }
        self = decoded
    }
}
