import Flutter
import Network
import UIKit

/// tvOS versions of the "plus" plugin channels the app talks to.
///
/// `device_info_plus`, `battery_plus` and `connectivity_plus` have no tvOS implementation, so every call to them
/// ended in a `MissingPluginException` (for example "No implementation found for method getDeviceInfo on channel
/// dev.fluttercommunity.plus/device_info"). The Dart packages are used unchanged; this answers the same channels
/// natively, with the same message shapes.
final class AppleTvPlusChannels: NSObject {
    private let deviceInfo: FlutterMethodChannel
    private let battery: FlutterMethodChannel
    private let batteryEvents: FlutterEventChannel
    private let connectivity: FlutterMethodChannel
    private let connectivityEvents: FlutterEventChannel

    private let connectivityStream = ConnectivityStream()
    private let batteryStream = BatteryStream()

    init(messenger: FlutterBinaryMessenger) {
        deviceInfo = FlutterMethodChannel(name: "dev.fluttercommunity.plus/device_info", binaryMessenger: messenger)
        battery = FlutterMethodChannel(name: "dev.fluttercommunity.plus/battery", binaryMessenger: messenger)
        batteryEvents = FlutterEventChannel(name: "dev.fluttercommunity.plus/charging", binaryMessenger: messenger)
        connectivity = FlutterMethodChannel(name: "dev.fluttercommunity.plus/connectivity", binaryMessenger: messenger)
        connectivityEvents = FlutterEventChannel(
            name: "dev.fluttercommunity.plus/connectivity_status", binaryMessenger: messenger)
        super.init()

        deviceInfo.setMethodCallHandler { call, result in
            call.method == "getDeviceInfo" ? result(Self.deviceInfoMap()) : result(FlutterMethodNotImplemented)
        }

        // An Apple TV is always on mains power.
        battery.setMethodCallHandler { call, result in
            switch call.method {
            case "getBatteryLevel": result(100)
            case "isInBatterySaveMode": result(false)
            case "getBatteryState": result("full")
            default: result(FlutterMethodNotImplemented)
            }
        }
        batteryEvents.setStreamHandler(batteryStream)

        connectivity.setMethodCallHandler { [connectivityStream] call, result in
            call.method == "check" ? result(connectivityStream.current()) : result(FlutterMethodNotImplemented)
        }
        connectivityEvents.setStreamHandler(connectivityStream)
    }

    private static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    private static func deviceInfoMap() -> [String: Any] {
        let device = UIDevice.current
        var sys = utsname()
        uname(&sys)
        func text<T>(_ value: T) -> String {
            withUnsafePointer(to: value) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
            }
        }
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        #if targetEnvironment(simulator)
        let physical = false
        #else
        let physical = true
        #endif
        return [
            "name": device.name,
            "systemName": device.systemName,
            "systemVersion": device.systemVersion,
            "model": device.model,
            "modelName": machine(),
            "localizedModel": device.localizedModel,
            "identifierForVendor": device.identifierForVendor?.uuidString ?? "",
            "freeDiskSize": (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0,
            "totalDiskSize": (attributes?[.systemSize] as? NSNumber)?.int64Value ?? 0,
            "isPhysicalDevice": physical,
            "physicalRamSize": Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
            "availableRamSize": Int(os_proc_available_memory() / 1_048_576),
            "isiOSAppOnMac": false,
            "isiOSAppOnVision": false,
            "utsname": [
                "sysname": text(sys.sysname),
                "nodename": text(sys.nodename),
                "release": text(sys.release),
                "version": text(sys.version),
                "machine": text(sys.machine),
            ],
        ]
    }
}

/// Reports the network type the way connectivity_plus expects: a list of "wifi", "ethernet", "other" or "none".
private final class ConnectivityStream: NSObject, FlutterStreamHandler {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "diapason.connectivity")
    private var sink: FlutterEventSink?
    private var latest: [String] = ["none"]

    override init() {
        super.init()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let types = Self.types(path)
            self.latest = types
            DispatchQueue.main.async { self.sink?(types) }
        }
        monitor.start(queue: queue)
    }

    func current() -> [String] {
        let types = Self.types(monitor.currentPath)
        return types
    }

    private static func types(_ path: NWPath) -> [String] {
        guard path.status == .satisfied else { return ["none"] }
        var found: [String] = []
        if path.usesInterfaceType(.wifi) { found.append("wifi") }
        if path.usesInterfaceType(.wiredEthernet) { found.append("ethernet") }
        if path.usesInterfaceType(.cellular) { found.append("mobile") }
        if found.isEmpty { found.append("other") }
        return found
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        events(latest)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}

private final class BatteryStream: NSObject, FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        events("full")
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? { nil }
}
