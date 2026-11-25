import 'package:diapason/utils/isar_fast_hash.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Values produced by the original inline FNV-1a implementation (literal
  // 0xcbf29ce484222325). Isar ids already stored on disk depend on them.
  test('isarFastHash matches the original 64-bit FNV-1a on native', () {
    const expected = {
      '': -3750763034362895579,
      'track123': 7730102670091727608,
      'jf-abcde': 1787803213210556061,
      'Ünïcødé ✓': -7305579031096444770,
    };
    expected.forEach((input, hash) => expect(isarFastHash(input), hash, reason: input));
  });
}
