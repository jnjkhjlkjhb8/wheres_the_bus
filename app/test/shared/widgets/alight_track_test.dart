import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_confirm_bar.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_pick_capsule.dart';
import 'package:wheres_the_bus/shared/widgets/alight_track/alight_track_bell.dart';
import 'package:wheres_the_bus/shared/widgets/native_controls.dart';

import '../../support/helpers/fake_uikit.dart';

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

    testWidgets('on a UIKit bar it is a system button that commits', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final uiKit = FakeUiKit(NativeIconButton.viewType);
      var taps = 0;
      Future<void> pump({required bool active}) => tester.pumpWidget(
        _host(
          UiKitBarScope(
            child: AlightTrackBell(
              active: active,
              onTap: () => taps++,
              semanticLabel: active ? '已設定' : '設定',
            ),
          ),
        ),
      );
      await pump(active: false);
      await tester.pumpAndSettle();
      await uiKit.send(tester, 'tap');
      final idle = tester.widget<NativeIconButton>(
        find.byType(NativeIconButton),
      );
      await pump(active: true);
      final armed = tester.widget<NativeIconButton>(
        find.byType(NativeIconButton),
      );
      debugDefaultTargetPlatformOverride = null;

      expect((idle.symbol, idle.prominent, idle.label), ('bell', false, '設定'));
      expect(
        (armed.symbol, armed.prominent, armed.label),
        ('bell.badge.fill', true, '已設定'),
      );
      expect(taps, 1);
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
    testWidgets(
      'a pending start keeps one spinner and blocks duplicate starts',
      (
        tester,
      ) async {
        var starts = 0;
        await tester.pumpWidget(
          _host(
            AlightConfirmBar(
              targetName: '市政府',
              lead: 2,
              busy: true,
              onLeadChanged: (_) {},
              onStart: () => starts++,
              onCancel: () {},
            ),
          ),
        );
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await tester.tap(find.byType(CircularProgressIndicator));
        await tester.pump(const Duration(milliseconds: 100));
        expect(starts, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
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

    testWidgets('the dock sits on the raised surface, not the scaffold', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: const ColorScheme.dark(
              surface: Color(0xFF111111),
              surfaceContainerHigh: Color(0xFF282828),
            ),
          ),
          localizationsDelegates: AppI18n.localizationsDelegates,
          supportedLocales: AppI18n.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: AlightConfirmBar(
              targetName: '市政府',
              lead: 1,
              onLeadChanged: (_) {},
              onStart: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      final dock = tester.widget<Material>(
        find
            .ancestor(
              of: find.byType(SafeArea),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(dock.color, const Color(0xFF282828));
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(SafeArea),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(
        (box.decoration! as BoxDecoration).color,
        const Color(0xFF282828),
      );
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
