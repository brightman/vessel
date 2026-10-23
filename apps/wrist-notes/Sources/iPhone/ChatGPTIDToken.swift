import Foundation
import Security

/// Only ID tokens are JWTs in this client. Access and refresh tokens remain opaque.
enum ChatGPTIDToken {
    struct Identity { let subject: String; let email: String? }
    private struct Header: Decodable { let alg: String; let kid: String; let crit: [String]? }
    private struct Claims: Decodable {
        let iss: String
        let aud: Audience
        let sub: String
        let exp: Double
        let nonce: String?
        let email: String?
        let azp: String?
        enum Audience: Decodable {
            case one(String), many([String])
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(String.self) { self = .one(value) }
                else { self = .many(try container.decode([String].self)) }
            }
            var values: [String] { switch self { case .one(let value): return [value]; case .many(let values): return values } }
        }
    }
    private struct Keys: Decodable { let keys: [JWK] }
    private struct JWK: Decodable {
        let kty: String; let kid: String?; let alg: String?; let use: String?
        let n: String?; let e: String?; let key_ops: [String]?
    }

    static func validate(_ token: String, jwks: Data, clientID: String, nonce: String?, expectedSubject: String?, now: Date) throws -> Identity {
        do {
            guard token.utf8.count <= 32_768, jwks.count <= 262_144 else { throw ChatGPTError.invalidIdentity }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let headerData = Data(chatGPTBase64URL: parts[0]), let claimsData = Data(chatGPTBase64URL: parts[1]), let signature = Data(chatGPTBase64URL: parts[2]) else { throw ChatGPTError.invalidIdentity }
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: headerData)
            guard header.alg == "RS256", !header.kid.isEmpty, header.crit?.isEmpty ?? true else { throw ChatGPTError.invalidIdentity }
            let keys = try decoder.decode(Keys.self, from: jwks).keys.filter { $0.kid == header.kid }
            guard keys.count == 1, let key = keys.first, key.kty == "RSA", key.alg == nil || key.alg == "RS256",
                  key.use == nil || key.use == "sig", key.key_ops == nil || key.key_ops!.contains("verify"),
                  let n = key.n.flatMap({ Data(chatGPTBase64URL: $0) }), let e = key.e.flatMap({ Data(chatGPTBase64URL: $0) }),
                  (256...1024).contains(n.count), (1...8).contains(e.count), n.first != 0, e.first != 0,
                  let publicKey = SecKeyCreateWithData(derSequence(derInteger(n) + derInteger(e)) as CFData,
                    [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
                  SecKeyIsAlgorithmSupported(publicKey, .verify, .rsaSignatureMessagePKCS1v15SHA256),
                  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil)
            else { throw ChatGPTError.invalidIdentity }
            let claims = try decoder.decode(Claims.self, from: claimsData)
            guard claims.iss == "https://auth.openai.com", claims.aud.values.contains(clientID),
                  claims.aud.values.count == 1 || claims.azp == clientID,
                  claims.azp == nil || claims.azp == clientID, claims.exp.isFinite, claims.exp > now.timeIntervalSince1970,
                  ChatGPTAuthorizationAttempt.validIdentifier(claims.sub), nonce == nil || claims.nonce == nonce,
                  expectedSubject == nil || claims.sub == expectedSubject
            else { throw ChatGPTError.invalidIdentity }
            return Identity(subject: claims.sub, email: claims.email)
        } catch { throw ChatGPTError.invalidIdentity }
    }
    private static func derLength(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count; var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    private static func derInteger(_ bytes: Data) -> Data {
        let positive = bytes.first.map({ $0 & 0x80 != 0 }) == true ? Data([0]) + bytes : bytes
        return Data([0x02]) + derLength(positive.count) + positive
    }
    private static func derSequence(_ bytes: Data) -> Data { Data([0x30]) + derLength(bytes.count) + bytes }
}
