import 'package:flutter/foundation.dart' show kIsWeb;

/// FNV-1a 64-bit hash optimized for Dart Strings, as provided by the Isar
/// documentation. Used to derive stable Isar ids from string ids.
///
/// The 64-bit arithmetic only exists on native platforms. The web build (where
/// Isar is never opened, and JS numbers are doubles) uses a 32-bit FNV-1a
/// instead: stable within the web app, but not equal to the native value.
int isarFastHash(String string) {
  if (kIsWeb) return _fnv1a32(string);
  // Written as two 32-bit halves so dart2js accepts the literal; the VM
  // evaluates it to 0xcbf29ce484222325.
  var hash = 0xCBF29CE4 << 32 | 0x84222325;
  for (var i = 0; i < string.length; i++) {
    final codeUnit = string.codeUnitAt(i);
    hash ^= codeUnit >> 8;
    hash *= 0x100000001b3;
    hash ^= codeUnit & 0xFF;
    hash *= 0x100000001b3;
  }
  return hash;
}

int _fnv1a32(String string) {
  var hash = 0x811C9DC5;
  for (var i = 0; i < string.length; i++) {
    hash = _mul32(hash ^ string.codeUnitAt(i));
  }
  return hash;
}

/// `(h * 16777619) mod 2^32` without exceeding 2^53 in intermediate results:
/// 16777619 = 2^24 + 403, and only the low 8 bits of h survive the 2^24 term.
int _mul32(int h) => ((h * 403) + ((h & 0xFF) * 0x1000000)) & 0xFFFFFFFF;
