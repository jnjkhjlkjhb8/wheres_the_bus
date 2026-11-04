import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/shared/widgets/edge_fade.dart';

void main() {
  const boundary = ValueKey('boundary');

  Future<ByteData> render(
    WidgetTester tester, {
    required double height,
    double? extent,
  }) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 10,
              height: height,
              child: extent == null
                  ? const EdgeFade(
                      child: ColoredBox(color: Color(0xFFFF0000)),
                    )
                  : EdgeFade(
                      extent: extent,
                      child: const ColoredBox(color: Color(0xFFFF0000)),
                    ),
            ),
          ),
        ),
      ),
    );
    return (await tester.runAsync(() async {
      final obj =
          tester.renderObject(find.byKey(boundary)) as RenderRepaintBoundary;
      final image = await obj.toImage();
      return (await image.toByteData())!;
    }))!;
  }

  int alphaAt(ByteData data, int y, {int width = 10}) =>
      data.getUint8((y * width) * 4 + 3);

  testWidgets('body stays opaque and the last extent px dissolve', (
    tester,
  ) async {
    final data = await render(tester, height: 100, extent: 20);
    expect(alphaAt(data, 0), 255);
    expect(alphaAt(data, 79), 255);
    expect(alphaAt(data, 90), inInclusiveRange(100, 160));
    expect(alphaAt(data, 99), lessThan(25));
  });

  testWidgets('a box shorter than extent fades from the top', (tester) async {
    final data = await render(tester, height: 10);
    expect(alphaAt(data, 0), greaterThan(alphaAt(data, 9)));
    expect(alphaAt(data, 9), lessThan(255 ~/ 2));
  });

  testWidgets('default extent is 24px', (tester) async {
    final data = await render(tester, height: 100);
    // The fade starts at 76: a different default would move this boundary.
    expect(alphaAt(data, 75), 255);
    expect(alphaAt(data, 76), inInclusiveRange(245, 254));
  });
}
