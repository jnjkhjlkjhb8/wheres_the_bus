import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_confirm_bar.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_pick_capsule.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_track_bell.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: AppI18n.localizationsDelegates,
  supportedLocales: AppI18n.supportedLocales,
  locale: const Locale('zh'),
  home: Scaffold(body: child),
);

void main() {
  group('AlightTrackBell', () {
    testWidgets('the icon states the session, not the tap', (tester) async {
      await tester.pumpWidget(
        _host(
          AlightTrackBell(
            active: false,
            onTap: () {},
            semanticLabel: '設定下車提醒',
          ),
        ),
      );
      expect(find.byIcon(Icons.notifications_none_rounded), findsOneWidget);

      await tester.pumpWidget(
        _host(
          AlightTrackBell(
            active: true,
            onTap: () {},
            semanticLabel: '下車提醒已設定',
          ),
        ),
      );
      expect(find.byIcon(Icons.notifications_active_rounded), findsOneWidget);
    });

    testWidgets('keeps a 44px touch target around its 40px circle', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AlightTrackBell(active: false, onTap: () {}, semanticLabel: 'x'),
        ),
      );
      expect(
        tester.getSize(find.byType(AlightTrackBell)),
        const Size(44, 44),
      );
    });
  });

  group('AlightPickCapsule', () {
    testWidgets('says the mode and offers the way out', (tester) async {
      var cancelled = 0;
      await tester.pumpWidget(
        _host(AlightPickCapsule(onCancel: () => cancelled++)),
      );

      expect(find.text('選擇下車站'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(cancelled, 1);
    });

    testWidgets('the host only shows it while picking', (tester) async {
      await tester.pumpWidget(
        _host(
          const AlightPickCapsuleHost(
            picking: false,
            onCancel: _noop,
            child: SizedBox.expand(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Present but fully transparent, so turning the mode on is a fade and
      // not a layout change.
      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacity.opacity, 0);
    });
  });

  group('AlightConfirmBar', () {
    testWidgets('hands back the lead the rider actually set', (tester) async {
      var lead = 2;
      final started = <int>[];
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => AlightConfirmBar(
              targetName: '市政府',
              lead: lead,
              onLeadChanged: (v) => setState(() => lead = v),
              onStart: () => started.add(lead),
              onCancel: () {},
            ),
          ),
        ),
      );

      expect(find.text('下車站 市政府'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pump();
      await tester.tap(find.text('開始追蹤'));
      expect(started, [3]);
    });

    testWidgets('an incomplete binding blocks the CTA on its own', (
      tester,
    ) async {
      final started = <int>[];
      await tester.pumpWidget(
        _host(
          AlightConfirmBar(
            targetName: '市政府',
            lead: 2,
            canStart: false,
            onLeadChanged: (_) {},
            onStart: () => started.add(2),
            onCancel: () {},
          ),
        ),
      );

      await tester.tap(find.text('開始追蹤'));
      expect(started, isEmpty, reason: 'binding is incomplete');
    });

    testWidgets('a destination that filled itself in says so', (tester) async {
      await tester.pumpWidget(
        _host(
          AlightConfirmBar(
            targetName: '臺中',
            lead: 2,
            fromSearch: true,
            onLeadChanged: (_) {},
            onStart: () {},
            onCancel: () {},
          ),
        ),
      );

      expect(find.textContaining('來自你的查詢'), findsOneWidget);
    });
  });

  group('AlightManageBar', () {
    testWidgets('cancelling is its own control, not the bell', (tester) async {
      var cancelled = 0;
      var closed = 0;
      await tester.pumpWidget(
        _host(
          AlightManageBar(
            targetName: '大安',
            lead: 2,
            bindingLabel: '1021 車',
            onClose: () => closed++,
            onCancel: () => cancelled++,
          ),
        ),
      );

      expect(find.text('往 大安 · 前 2 站提醒'), findsOneWidget);
      expect(find.text('1021 車'), findsOneWidget);

      await tester.tap(find.text('關閉'));
      expect(closed, 1);
      expect(cancelled, 0);

      await tester.tap(find.text('取消提醒'));
      expect(cancelled, 1);
    });
  });
}

void _noop() {}
