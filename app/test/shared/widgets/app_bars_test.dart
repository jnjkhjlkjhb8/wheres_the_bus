import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/adapters.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/bookmark_button.dart';
import 'package:wheres_the_bus/shared/widgets/native_controls.dart';
import 'package:wheres_the_bus/shared/widgets/native_nav_bar.dart';

import '../../support/helpers/fake_uikit.dart';
import '../../support/helpers/i18n.dart';

void main() {
  BoxDecoration barDecoration(WidgetTester tester) {
    final container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(DetailAppBar),
        matching: find.byType(AnimatedContainer),
      ),
    );
    return container.decoration! as BoxDecoration;
  }

  testWidgets('every bar reaches for the same back glyph', (tester) async {
    await tester.pumpWidget(
      i18nApp(
        const Scaffold(
          appBar: DetailAppBar(title: '設定'),
          body: FloatingAppBar(),
        ),
      ),
    );

    final icons = tester
        .widgetList<Icon>(
          find.descendant(
            of: find.byType(AppBarBackButton),
            matching: find.byType(Icon),
          ),
        )
        .toList();
    expect(icons, hasLength(2));
    for (final icon in icons) {
      expect(icon.icon, Icons.arrow_back_ios_new_rounded);
      expect(icon.size, AppBarMetrics.icon);
    }
  });

  // The floating variant wears the circular plate; the bare one does not. Both
  // keep the 44pt target, so the glyph lands in the same place either way.
  testWidgets('floating flag only swaps the backing plate', (tester) async {
    await tester.pumpWidget(
      i18nApp(
        const Scaffold(
          body: Column(
            children: [
              AppBarBackButton(),
              AppBarBackButton(floating: true),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(AppBarCircleButton), findsOneWidget);
    for (final (i, circled) in [(0, false), (1, true)]) {
      expect(
        find.descendant(
          of: find.byType(AppBarBackButton).at(i),
          matching: find.byType(AppBarCircleButton),
        ),
        circled ? findsOneWidget : findsNothing,
      );
    }
    for (var i = 0; i < 2; i++) {
      expect(
        tester.getSize(find.byType(AppBarBackButton).at(i)),
        const Size.square(AppBarMetrics.tapTarget),
      );
    }
  });

  // The circular plate is 40pt wide, so a child that carries its own 44pt tap
  // padding gets squeezed: the glyph keeps painting at its full size out of a
  // shrunken box and drifts off the plate's centre.
  testWidgets('a bookmark on the circular plate sits on its centre', (
    tester,
  ) async {
    final favorites = FavoritesBloc(
      _FakeFavoritesRepository(),
      ValueNotifier(true),
    );
    addTearDown(favorites.close);

    await tester.pumpWidget(
      i18nApp(
        BlocProvider<FavoritesBloc>.value(
          value: favorites,
          child: const Scaffold(
            body: FloatingAppBar(
              middle: AppBarTitlePill(title: '261'),
              trailing: AppBarCircleButton(
                child: BookmarkButton(
                  routeType: 'bus',
                  routeKey: 'sub-1',
                  routeLabel: '261',
                  onPlate: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final glyph = find.descendant(
      of: find.byType(BookmarkButton),
      matching: find.byType(Icon),
    );
    final plate = find.ancestor(
      of: find.byType(BookmarkButton),
      matching: find.byType(AppBarCircleButton),
    );

    expect(tester.getSize(glyph), const Size.square(AppBarMetrics.icon));
    expect(tester.getCenter(glyph), tester.getCenter(plate));
  });

  testWidgets('DetailAppBar has no divider until content passes under it', (
    tester,
  ) async {
    await tester.pumpWidget(
      i18nApp(
        Scaffold(
          appBar: const DetailAppBar(title: '票價', subtitle: '07/29 (三)'),
          body: ListView(
            children: List.generate(
              40,
              (i) => SizedBox(height: 60, child: Text('$i')),
            ),
          ),
        ),
      ),
    );

    expect(barDecoration(tester).border, isNull);
    expect(barDecoration(tester).boxShadow, isEmpty);

    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();

    // Surface-coloured, so the content dissolves into the bar rather than
    // meeting a rule.
    final shadow = barDecoration(tester).boxShadow!.single;
    expect(shadow.color, barDecoration(tester).color);
    expect(shadow.blurRadius, greaterThan(0));
  });

  testWidgets('the title pill and the bar share one type ramp', (tester) async {
    await tester.pumpWidget(
      i18nApp(
        const Scaffold(
          appBar: DetailAppBar(title: '台北 → 高雄', subtitle: '07/29 (三)'),
          body: FloatingAppBar(
            middle: AppBarTitlePill(title: '台北 → 高雄', subtitle: '07/29 (三)'),
          ),
        ),
      ),
    );

    final titles = tester
        .widgetList<Text>(find.text('台北 → 高雄'))
        .map((t) => t.style)
        .toList();
    expect(titles, hasLength(2));
    expect(titles.first!.fontSize, titles.last!.fontSize);
    expect(titles.first!.fontWeight, titles.last!.fontWeight);

    // Dates and counts must not reflow a pixel every time a digit ticks.
    for (final text in tester.widgetList<Text>(find.text('07/29 (三)'))) {
      expect(text.style!.fontFeatures, isNotEmpty);
    }
  });

  testWidgets('a subtitle tightens the title and follows the alignment', (
    tester,
  ) async {
    Future<void> mount({required bool centered, String? subtitle}) =>
        tester.pumpWidget(
          i18nApp(
            Scaffold(
              appBar: DetailAppBar(
                title: '票價',
                subtitle: subtitle,
                centerTitle: centered,
              ),
            ),
          ),
        );
    double? heightOf(String text) =>
        tester.widget<Text>(find.text(text)).style!.height;

    await mount(centered: false);
    expect(heightOf('票價'), AppTextStyles.bodyLarge.height);

    await mount(centered: false, subtitle: '07/29 (三)');
    expect(heightOf('票價'), 1.2);
    expect(heightOf('07/29 (三)'), 1.2);
    Column titleColumn() => tester.widget<Column>(
      find
          .ancestor(of: find.text('07/29 (三)'), matching: find.byType(Column))
          .first,
    );
    expect(titleColumn().crossAxisAlignment, CrossAxisAlignment.start);

    await mount(centered: true, subtitle: '07/29 (三)');
    expect(titleColumn().crossAxisAlignment, CrossAxisAlignment.center);
  });

  testWidgets('a removed bar stops listening to scrolls', (tester) async {
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    await tester.pumpWidget(
      i18nApp(
        Material(
          child: ScrollNotificationObserver(
            child: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (_, on, _) => Column(
                children: [
                  if (on) const DetailAppBar(title: '票價'),
                  Expanded(
                    child: ListView(children: const [SizedBox(height: 2000)]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    shown.value = false;
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a bar moved to another observer follows only that one', (
    tester,
  ) async {
    final barKey = GlobalKey();
    final inFirst = ValueNotifier(true);
    addTearDown(inFirst.dispose);
    Widget list(String name) => Expanded(
      child: ListView(
        key: ValueKey(name),
        children: const [SizedBox(height: 2000)],
      ),
    );
    await tester.pumpWidget(
      i18nApp(
        Material(
          child: ValueListenableBuilder<bool>(
            valueListenable: inFirst,
            builder: (_, first, _) => Column(
              children: [
                Expanded(
                  child: ScrollNotificationObserver(
                    child: Column(
                      children: [
                        if (first)
                          KeyedSubtree(
                            key: barKey,
                            child: const DetailAppBar(title: '票價'),
                          ),
                        list('first'),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ScrollNotificationObserver(
                    child: Column(
                      children: [
                        if (!first)
                          KeyedSubtree(
                            key: barKey,
                            child: const DetailAppBar(title: '票價'),
                          ),
                        list('second'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    inFirst.value = false;
    await tester.pump();

    await tester.drag(
      find.byKey(const ValueKey('first')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(barDecoration(tester).boxShadow, isEmpty);

    await tester.drag(
      find.byKey(const ValueKey('second')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(barDecoration(tester).boxShadow, hasLength(1));
  });

  group('AppBarTitlePill', () {
    testWidgets('is a plain label without a tap handler', (tester) async {
      await tester.pumpWidget(
        i18nApp(const Scaffold(body: AppBarTitlePill(title: '261'))),
      );

      expect(find.text('261'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
      expect(find.byType(Pressable), findsNothing);
    });

    testWidgets('becomes a labelled button with a chevron', (tester) async {
      var taps = 0;
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        i18nApp(
          Scaffold(
            body: AppBarTitlePill(
              title: '261',
              onTap: () => taps++,
              semanticLabel: 'Switch route',
            ),
          ),
        ),
      );

      final chevron = tester.widget<Icon>(
        find.byIcon(Icons.expand_more_rounded),
      );
      expect(chevron.size, AppBarMetrics.icon);
      expect(
        tester.getSemantics(find.byType(Pressable)).label,
        contains('Switch route'),
      );
      // The title gives way to the chevron instead of pushing it off the pill.
      expect(
        find.descendant(
          of: find.byType(AppBarTitlePill),
          matching: find.byType(Expanded),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('261'));
      expect(taps, 1);
      handle.dispose();
    });
  });

  group('DetailAppBar on iOS', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    testWidgets('UIKit draws back and title; actions stay Flutter on top', (
      tester,
    ) async {
      final uiKit = FakeUiKit(NativeNavBar.viewType);
      var backs = 0;
      var actionTaps = 0;
      await tester.pumpWidget(
        i18nApp(
          Scaffold(
            appBar: DetailAppBar(
              title: '自強 123',
              subtitle: '07/29 (三)',
              onBack: () => backs++,
              actions: [
                Pressable(
                  onTap: () => actionTaps++,
                  child: const SizedBox.square(
                    dimension: AppBarMetrics.tapTarget,
                    child: Text('a'),
                  ),
                ),
                const SizedBox.square(dimension: AppBarMetrics.tapTarget),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('a'));
      await uiKit.send(tester, 'back');
      final bar = tester.getRect(find.byType(DetailAppBar));
      final native = tester.getRect(find.byType(NativeNavBar));
      final action = tester.getRect(find.text('a'));
      final flutterChrome = [
        find.byType(AppBarBackButton),
        find.byType(NavigationToolbar),
        find.text('自強 123'),
      ].map((f) => f.evaluate().length).toList();
      debugDefaultTargetPlatformOverride = null;

      expect(flutterChrome, [0, 0, 0]);
      expect(
        UiKitBarScope.of(tester.element(find.text('a'))),
        isTrue,
        reason: 'actions on the native bar draw as system buttons',
      );
      final params = uiKit.creationParams();
      expect(params['title'], '自強 123');
      expect(params['subtitle'], '07/29 (三)');
      // Two actions, one tap target each, kept clear of the system title.
      expect(params['trailingWidth'], 2 * AppBarMetrics.tapTarget);
      expect(backs, 1);
      expect(actionTaps, 1);

      // The UIKit bar spans the slot's width and hugs its top, leaving the
      // slot's spare height as air above the content.
      expect(native.width, bar.width);
      expect(native.height, NativeNavBar.height);
      expect(native.top, bar.bottom - AppBarMetrics.barHeight);
      // Actions sit over the bar's trailing edge, inside its height.
      expect(action.top, greaterThanOrEqualTo(native.top));
      expect(action.bottom, lessThanOrEqualTo(native.bottom));
      expect(action.right, bar.right - 8 - AppBarMetrics.tapTarget);
    });

    testWidgets('no title and no actions reserve nothing', (tester) async {
      final uiKit = FakeUiKit(NativeNavBar.viewType);
      await tester.pumpWidget(
        i18nApp(const Scaffold(appBar: DetailAppBar())),
      );
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;

      final params = uiKit.creationParams();
      expect(params['title'], '');
      expect(params['subtitle'], isNull);
      expect(params['trailingWidth'], 0.0);
    });

    testWidgets('still dissolves content that scrolls under it', (
      tester,
    ) async {
      FakeUiKit(NativeNavBar.viewType);
      await tester.pumpWidget(
        i18nApp(
          Scaffold(
            appBar: const DetailAppBar(title: '票價'),
            body: ListView(
              children: List.generate(
                40,
                (i) => SizedBox(height: 60, child: Text('$i')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = barDecoration(tester).boxShadow;
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      final after = barDecoration(tester).boxShadow;
      debugDefaultTargetPlatformOverride = null;

      expect(before, isEmpty);
      expect(after, isNotEmpty);
    });
  });
}

class _FakeFavoritesRepository implements FavoritesRepository {
  @override
  bool get isReady => true;

  @override
  Stream<BoxEvent> watch() => const Stream.empty();

  @override
  Stream<void> changes() => const Stream.empty();

  @override
  List<Favorite> all() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
