import Flutter
import Foundation

/// Bonjour for Diapason Connect on tvOS.
///
/// The `nsd` plugin Connect uses everywhere else has no tvOS implementation, so the Apple TV announces itself
/// and finds the other Diapason devices through Foundation's NetService here instead. The Dart side is
/// `TvOsMdns` in `lib/services/connect/connect_mdns.dart`.
///
/// Methods: `register {name, type, port, txt}`, `unregister`, `startBrowse {type}`, `stopBrowse`.
/// Pushed back to Dart: `services` with every device found so far, each `{name, host, port, txt}`.
final class AppleTvBonjourChannel: NSObject {
    static let channelName = "fr.nytuo.diapason/appletv_bonjour"

    private let channel: FlutterMethodChannel
    private var published: NetService?
    private var browser: NetServiceBrowser?
    private var pending: [String: NetService] = [:]
    private var resolved: [String: [String: Any]] = [:]

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "register":
            guard let name = args["name"] as? String, let type = args["type"] as? String, let port = args["port"] as? Int else {
                result(FlutterError(code: "bad_args", message: "register needs name, type and port", details: nil))
                return
            }
            published?.stop()
            let service = NetService(domain: "local.", type: Self.withDot(type), name: name, port: Int32(port))
            if let txt = args["txt"] as? [String: String] {
                service.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
            }
            service.delegate = self
            service.publish()
            published = service
            result(nil)
        case "unregister":
            published?.stop()
            published = nil
            result(nil)
        case "startBrowse":
            guard let type = args["type"] as? String else {
                result(FlutterError(code: "bad_args", message: "startBrowse needs a type", details: nil))
                return
            }
            stopBrowsing()
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: Self.withDot(type), inDomain: "local.")
            self.browser = browser
            result(nil)
        case "stopBrowse":
            stopBrowsing()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func stopBrowsing() {
        browser?.stop()
        browser = nil
        pending.values.forEach { $0.stop() }
        pending.removeAll()
        resolved.removeAll()
    }

    private static func withDot(_ type: String) -> String { type.hasSuffix(".") ? type : type + "." }

    private func push() {
        channel.invokeMethod("services", arguments: Array(resolved.values))
    }

    /// The first IPv4 address of a resolved service, as text. Connecting by address avoids depending on `.local`
    /// name resolution from Dart.
    private static func ipv4(of service: NetService) -> String? {
        for data in service.addresses ?? [] {
            let text: String? = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let sockaddr = base.assumingMemoryBound(to: sockaddr.self)
                guard sockaddr.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(sockaddr, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return status == 0 ? String(cString: host) : nil
            }
            if let text { return text }
        }
        return nil
    }
}

extension AppleTvBonjourChannel: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        pending[service.name] = service
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        pending.removeValue(forKey: service.name)
        resolved.removeValue(forKey: service.name)
        push()
    }
}

extension AppleTvBonjourChannel: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        var txt: [String: String] = [:]
        if let data = sender.txtRecordData() {
            for (key, value) in NetService.dictionary(fromTXTRecord: data) {
                txt[key] = String(data: value, encoding: .utf8) ?? ""
            }
        }
        resolved[sender.name] = [
            "name": sender.name,
            "host": Self.ipv4(of: sender) ?? sender.hostName ?? "",
            "port": sender.port,
            "txt": txt,
        ]
        push()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pending.removeValue(forKey: sender.name)
    }
}
