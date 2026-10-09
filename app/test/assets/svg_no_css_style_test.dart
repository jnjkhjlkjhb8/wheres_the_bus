import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SVG assets do not rely on CSS <style> blocks', () {
    final offenders = Directory('assets')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.svg'))
        .where((f) => f.readAsStringSync().contains('<style'))
        .map((f) => f.path)
        .toList();
    expect(
      offenders,
      isEmpty,
      reason: 'Inline the fills (fill="...") in: $offenders',
    );
  });
}
