import Flutter
import Foundation
import UIKit

final class AppleTvBonjourChannel: NSObject {
    static let channelName = "fr.nytuo.diapason/appletv_bonjour"

    private let channel: FlutterMethodChannel
    private var published: NetService?
    private var browsers: [String: NetServiceBrowser] = [:]
    private var pending: [String: [String: NetService]] = [:]
    private var resolved: [String: [String: [String: Any]]] = [:]
    private var announcement: (name: String, type: String, port: Int32, txt: [String: String]?)?
    private var publishRetries = 0

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler(handle)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func didBecomeActive() {
        publishRetries = 0
        publish()
        for type in Array(browsers.keys) { startBrowsing(type) }
    }

    private func log(_ message: String) {
        NSLog("[AppleTvBonjour] %@", message)
        channel.invokeMethod("log", arguments: message)
    }

    private func publish() {
        published?.delegate = nil
        published?.stop()
        published = nil
        guard let announcement else { return }
        let service = NetService(
            domain: "local.", type: Self.withDot(announcement.type), name: announcement.name, port: announcement.port)
        if let txt = announcement.txt {
            service.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data($0.utf8) }))
        }
        service.delegate = self
        service.publish()
        published = service
    }

    private func startBrowsing(_ type: String) {
        let type = Self.withDot(type)
        stopBrowsing(type)
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: type, inDomain: "local.")
        browsers[type] = browser
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "register":
            guard let name = args["name"] as? String, let type = args["type"] as? String, let port = args["port"] as? Int else {
                result(FlutterError(code: "bad_args", message: "register needs name, type and port", details: nil))
                return
            }
            announcement = (name, type, Int32(port), args["txt"] as? [String: String])
            publishRetries = 0
            publish()
            result(nil)
        case "unregister":
            announcement = nil
            publish()
            result(nil)
        case "startBrowse":
            guard let type = args["type"] as? String else {
                result(FlutterError(code: "bad_args", message: "startBrowse needs a type", details: nil))
                return
            }
            startBrowsing(type)
            result(nil)
        case "stopBrowse":
            if let type = args["type"] as? String {
                stopBrowsing(Self.withDot(type))
            } else {
                for type in Array(browsers.keys) { stopBrowsing(type) }
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func stopBrowsing(_ type: String) {
        if let browser = browsers.removeValue(forKey: type) {
            browser.delegate = nil
            browser.stop()
        }
        pending.removeValue(forKey: type)?.values.forEach { $0.stop() }
        resolved.removeValue(forKey: type)
    }

    private static func withDot(_ type: String) -> String { type.hasSuffix(".") ? type : type + "." }

    private func push(_ type: String) {
        channel.invokeMethod(
            "services", arguments: ["type": type, "services": Array((resolved[type] ?? [:]).values)] as [String: Any])
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
        let type = Self.withDot(service.type)
        guard browsers[type] != nil else { return }
        service.delegate = self
        pending[type, default: [:]][service.name] = service
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        log("Browsing the network failed: \(errorDict)")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let type = Self.withDot(service.type)
        pending[type]?.removeValue(forKey: service.name)
        resolved[type]?.removeValue(forKey: service.name)
        push(type)
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
        let type = Self.withDot(sender.type)
        guard browsers[type] != nil else { return }
        resolved[type, default: [:]][sender.name] = [
            "name": sender.name,
            "host": Self.ipv4(of: sender) ?? sender.hostName ?? "",
            "port": sender.port,
            "txt": txt,
        ]
        push(type)
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === published else { return }
        publishRetries = 0
        log("Announced as '\(sender.name)'")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === published else { return }
        log("Announcing on the network failed: \(errorDict)")
        guard publishRetries < 5 else { return }
        publishRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(publishRetries) * 2) { [weak self] in
            guard let self, self.published === sender else { return }
            self.publish()
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pending[Self.withDot(sender.type)]?.removeValue(forKey: sender.name)
    }
}
