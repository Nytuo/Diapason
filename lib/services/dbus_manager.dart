import 'dart:io';
import 'package:dbus/dbus.dart';
import 'package:diapason/extensions/string.dart';
import 'package:diapason/services/finamp_settings_helper.dart';
import 'package:diapason/services/theme_provider.dart';
import 'package:logging/logging.dart';

final _logger = Logger("dBus");

bool _shouldUseDBus() {
  return Platform.isLinux;
}

Future<DBusMethodResponse> _updateAccentColor() async {
  await fetchSystemPalette();
  return DBusMethodSuccessResponse([DBusBoolean(true)]);
}

Future<DBusMethodResponse> _setAccentColor(String text) async {
  _logger.fine("request to set Accent color to $text");

  if (text == "default") {
    FinampSetters.setAccentColor(null);
    return DBusMethodSuccessResponse([DBusBoolean(true)]);
  }

  final color = text.toColorOrNull();
  if (color == null) return DBusMethodErrorResponse.failed("Invalid color");

  FinampSetters.setAccentColor(color);
  return DBusMethodSuccessResponse([DBusBoolean(true)]);
}

class _DBusEndpoints extends DBusObject {
  _DBusEndpoints() : super(DBusObjectPath('/fr/nytuo/Diapason'));

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != 'fr.nytuo.Diapason') return DBusMethodErrorResponse.unknownInterface();

    switch (call.name) {
      case "updateAccentColor":
        return _updateAccentColor();
      case "setAccentColor":
        return _setAccentColor(call.values[0].asString());
    }

    _logger.info("Received message but couldn't handle it");
    return super.handleMethodCall(call);
  }
}

Future<void> initDBus() async {
  if (!_shouldUseDBus()) return;
  _logger.info("Device is allowed to use dBus");

  final client = DBusClient.session();

  try {
    await client.requestName('fr.nytuo.DiapasonSettings');
    await client.registerObject(_DBusEndpoints());
  } catch (e) {
    _logger.warning("Failed to register object: $e");
    await client.close();
  }

  _logger.info("init finished");
}
