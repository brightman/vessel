import Foundation
import Security

struct DesktopTLSIdentity {
    let identity: SecIdentity
    let certificateHash: String
    private struct Archive: Codable { let pkcs12: Data; let password: String }
    static func load(keychain: SyncKeychain) throws -> Self {
        let archive: Archive
        if let data = try keychain.read("tls-identity") { archive = try DesktopSyncCodec.decode(Archive.self, data) }
        else {
            archive = try generate()
            try keychain.write(DesktopSyncCodec.encode(archive), account: "tls-identity")
        }
        return try decode(archive)
    }
    /// Test identities are never written to the user's Keychain.
    static func ephemeral() throws -> Self { try decode(generate()) }
    private static func decode(_ archive: Archive) throws -> Self {
        var result: CFArray?
        let status = SecPKCS12Import(archive.pkcs12 as CFData, [kSecImportExportPassphrase as String: archive.password, kSecImportToMemoryOnly as String: true] as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]], let identity = items.first?[kSecImportItemIdentity as String] else { throw DesktopSyncError.invalid("无法读取 Mac 同步证书（\(status)）。") }
        let value = identity as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(value, &certificate) == errSecSuccess, let certificate else { throw DesktopSyncError.invalid("同步证书不可用。") }
        return .init(identity: value, certificateHash: DesktopSyncCodec.hash(SecCertificateCopyData(certificate) as Data))
    }
    private static func generate() throws -> Archive {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wiselife-tls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = DesktopSyncCodec.secret()
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "identity.key", "-out", "identity.crt", "-days", "3650", "-subj", "/CN=WiseLife Desktop"], directory: directory)
        try run(["pkcs12", "-export", "-inkey", "identity.key", "-in", "identity.crt", "-out", "identity.p12", "-passout", "stdin"], directory: directory, input: password + "\n")
        return Archive(pkcs12: try Data(contentsOf: directory.appendingPathComponent("identity.p12")), password: password)
    }
    private static func run(_ arguments: [String], directory: URL, input: String = "") throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let pipe = Pipe(); process.standardInput = pipe
        try process.run()
        try pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DesktopSyncError.invalid("无法创建本机同步证书。") }
    }
}
