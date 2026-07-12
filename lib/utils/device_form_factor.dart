import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:logging/logging.dart';

enum DeviceFormFactor {
  handheld,

  tv,

  watch;

  bool get isTv => this == DeviceFormFactor.tv;
  bool get isWatch => this == DeviceFormFactor.watch;
}

class DeviceFormFactorDetector {
  static final _log = Logger("DeviceFormFactor");

  static const _leanback = "android.software.leanback";
  static const _television = "android.hardware.type.television";
  static const _watch = "android.hardware.type.watch";

  static DeviceFormFactor _current = DeviceFormFactor.handheld;

  static DeviceFormFactor get current => _current;

  static Future<DeviceFormFactor> detect() async {
    if (!Platform.isAndroid) return _current = DeviceFormFactor.handheld;

    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final features = info.systemFeatures;

      if (features.contains(_watch)) {
        _current = DeviceFormFactor.watch;
      } else if (features.contains(_television) || features.contains(_leanback)) {
        _current = DeviceFormFactor.tv;
      } else {
        _current = DeviceFormFactor.handheld;
      }
    } catch (e) {
      _log.warning("Could not detect the device form factor: $e");
      _current = DeviceFormFactor.handheld;
    }

    _log.info("Running as ${_current.name}");
    return _current;
  }
}
