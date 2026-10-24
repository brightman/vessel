import Foundation
import Darwin
import SystemConfiguration

public struct LocalInterface: Sendable, Identifiable, Hashable {
    public let name: String
    public let address: String
    public var id: String { name + ":" + address }
    public static func displayName(for name: String) -> String {
        let interfaces = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        guard let interface = interfaces.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == name }) else { return "局域网连接" }
        return SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? "局域网连接"
    }
    public static func all() -> [Self] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [Self] = [], next = head
        while let current = next {
            defer { next = current.pointee.ifa_next }
            let item = current.pointee
            guard let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_UP) != 0, item.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: buffer), name = String(cString: item.ifa_name)
            if isPrivateIPv4(address), !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") {
                result.append(.init(name: name, address: address))
            }
        }
        return result.sorted { $0.name < $1.name }
    }
    public static func isPrivateIPv4(_ address: String) -> Bool {
        let p = address.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254)
    }
}

@MainActor public final class BonjourAdvertiser: NSObject, @preconcurrency NetServiceDelegate {
    public static let type = "_wiselife-llm._tcp."
    private var service: NetService?
    public private(set) var published = false
    public private(set) var failed = false
    public func publish(serviceID: String, port: Int) {
        stop(); failed = false
        let service = NetService(domain: "local.", type: Self.type, name: serviceID, port: Int32(port))
        service.setTXTRecord(NetService.data(fromTXTRecord: ["v": Data("1".utf8), "id": Data(serviceID.utf8)]))
        service.delegate = self; self.service = service; service.publish()
    }
    public func stop() { service?.stop(); service = nil; published = false }
    public func netServiceDidPublish(_ sender: NetService) { published = true }
    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) { published = false; failed = true }
}
