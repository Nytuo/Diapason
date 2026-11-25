import 'dart:ffi' show Abi;

/// Whether the running native binary is arm64 on a desktop OS (used to pick
/// release assets). See `native_abi_web.dart` for the web build.
bool get isDesktopArm64 => switch (Abi.current()) {
  Abi.windowsArm64 || Abi.linuxArm64 || Abi.macosArm64 => true,
  _ => false,
};
