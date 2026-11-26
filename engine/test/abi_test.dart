import 'dart:ffi';

import 'package:orchard_engine/src/bindings.dart';
import 'package:test/test.dart';

void main() {
  test('struct layouts match Rust (rust/src/lib.rs abi_tests)', () {
    expect(sizeOf<OeNote>(), 12);
    expect(sizeOf<OeOscParams>(), 32);
  });
}
