import Flutter
import Foundation

/// Reads app bundle metadata (name, identifier, version, build) for tvOS.
///
/// package_info_plus has no tvOS plugin implementation, and its tvOS fork
/// (package_info_plus_tvos) needs package_info_plus_platform_interface
/// ^4.1.0, which in turn needs package_info_plus >=10.0.0, which needs
/// win32 ^6.0.1 — incompatible with file_picker's win32 <6.0.0 constraint on
/// this shared pubspec. Rather than force that upgrade chain, this channel
/// hands back the same fields straight from Bundle.main so the Dart side can
/// build a PackageInfo without going through the plugin at all.
final class AppleTvSystemChannel: NSObject {
    static let channelName = "fr.nytuo.diapason/appletv_system"

    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler(handle)
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPackageInfo":
            result(packageInfo())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func packageInfo() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "appName": info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "",
            "packageName": Bundle.main.bundleIdentifier ?? "",
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "buildNumber": info["CFBundleVersion"] as? String ?? "",
        ]
    }
}
