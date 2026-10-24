import Foundation
import CryptoKit
import X509
import NIOSSL

public struct TLSIdentity: @unchecked Sendable {
    public let context: NIOSSLContext
    public let fingerprint: String
    public let certificateDER: Data
    private struct Archive: Codable { let certificate: String; let key: String }
    public static func load(store: any SecretStore, serviceID: String) throws -> Self {
        let archive: Archive
        if let data = try store.read("tls-identity") { archive = try JSONDecoder().decode(Archive.self, from: data) }
        else {
            archive = try generate(serviceID: serviceID)
            try store.write(JSONEncoder().encode(archive), account: "tls-identity")
        }
        let cert = try NIOSSLCertificate(bytes: Array(archive.certificate.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(archive.key.utf8), format: .pem)
        var config = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(cert)], privateKey: .privateKey(key))
        config.minimumTLSVersion = .tlsv12
        config.applicationProtocols = ["http/1.1"]
        let der = Data(try cert.toDERBytes())
        return try .init(context: NIOSSLContext(configuration: config), fingerprint: Secrets.hash(der), certificateDER: der)
    }
    private static func generate(serviceID: String) throws -> Archive {
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("WiseLife Mac Companion") }
        let certificate = try Certificate(version: .v3,
            serialNumber: .init(bytes: Array(SHA256.hash(data: Data(try Secrets.random().utf8))).prefix(16)),
            publicKey: .init(key.publicKey), notValidBefore: Date().addingTimeInterval(-300),
            notValidAfter: Date().addingTimeInterval(10 * 365 * 86400), issuer: name, subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([.dnsName(serviceID + ".local")])
            }, issuerPrivateKey: .init(key))
        return try Archive(certificate: certificate.serializeAsPEM().pemString, key: key.pemRepresentation)
    }
}
