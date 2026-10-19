import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/app/theme/notice_tone.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/alert_repository.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_bloc.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';
import 'package:wheres_the_bus/features/alerts/view/notification_sheet.dart';

import '../../../support/helpers/i18n.dart';
import '../../../support/helpers/in_memory_settings_store.dart';

const _tra = AlertSource(AlertSourceKind.tra);
const _notice = AlertSource(AlertSourceKind.appNotice);

// Test fonts are Ahem: every glyph is exactly fontSize wide, so a run of N
// characters wraps at floor(width / fontSize) per line.
String _run(int n) => '字' * n;

Future<void> _open(
  WidgetTester tester,
  List<(AlertSource, AlertViewModel)> alerts, {
  bool markRead = true,
}) async {
  final bloc = AlertBloc(
    repository: AlertRepository(
      settings: SettingsRepository(store: InMemorySettingsStore(const {})),
    ),
  );
  addTearDown(bloc.close);
  for (final (source, alert) in alerts) {
    bloc.add(AlertReceived(source, [alert]));
    await bloc.stream.first;
  }
  if (markRead) {
    bloc.add(const AlertAllRead());
    await bloc.stream.first;
  }
  await tester.pumpWidget(
    i18nApp(
      BlocProvider.value(
        value: bloc,
        child: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showNotificationSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

AlertViewModel _alert(
  String message, {
  AlertSeverity level = AlertSeverity.yellow,
  String? title,
  DateTime? time,
  AlertSource? source,
}) => AlertViewModel(
  message: message,
  level: level,
  title: title,
  time: time,
  source: source,
);

TextStyle _styleOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!;

ColorScheme _scheme(WidgetTester tester) =>
    Theme.of(tester.element(find.text(zhStrings.alertsTitle))).colorScheme;

Finder _rowSurface(ColorScheme cs) => find.byWidgetPredicate((w) {
  if (w is! Container) return false;
  final d = w.decoration;
  return d is BoxDecoration &&
      d.border is Border &&
      (d.border! as Border).top.color ==
          cs.outlineVariant.withValues(alpha: 0.5);
});

int _gaps(WidgetTester tester) => find
    .byWidgetPredicate(
      (w) => w is SizedBox && w.width == AppTheme.space8 && w.height == null,
    )
    .evaluate()
    .length;

void main() {
  testWidgets('sheet is 72% of the screen height', (tester) async {
    await _open(tester, [(_tra, _alert('a', source: _tra))]);

    final sheet = find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final d = w.decoration;
      return d is BoxDecoration &&
          d.borderRadius ==
              const BorderRadius.vertical(
                top: Radius.circular(AppTheme.radiusBottomSheet),
              );
    });
    expect(tester.getSize(sheet).height, 600 * 0.72);
  });

  testWidgets('group headings show label and count in their styles', (
    tester,
  ) async {
    await _open(tester, [
      (_tra, _alert('壞了', source: _tra)),
      (_notice, _alert('公告', source: _notice)),
    ]);
    final cs = _scheme(tester);

    expect(find.text(zhStrings.alertsGroupOngoing), findsOneWidget);
    expect(find.text(zhStrings.alertsGroupMessages), findsOneWidget);
    final label = _styleOf(tester, zhStrings.alertsGroupOngoing);
    expect(label.fontWeight, FontWeight.w600);
    expect(label.color, cs.onSurfaceVariant);
    final counts = find.text('1');
    expect(counts, findsNWidgets(2));
    final count = tester.widget<Text>(counts.first).style!;
    expect(count.fontSize, 11.5);
    expect(count.height, 1);
    expect(count.color, cs.outline);
  });

  testWidgets('row text styles, relative time and publish footer', (
    tester,
  ) async {
    await _open(tester, [
      (_tra, _alert('內文', title: '標題', time: DateTime.now(), source: _tra)),
    ]);
    final cs = _scheme(tester);

    final title = _styleOf(tester, '標題');
    expect(title.fontSize, 15);
    expect(title.height, 1.4);
    expect(title.color, cs.onSurface);
    expect(title.fontWeight, FontWeight.w400);
    final body = _styleOf(tester, '內文');
    expect(body.fontSize, 13.5);
    expect(body.height, 1.5);
    expect(body.color, cs.onSurfaceVariant);
    final time = _styleOf(tester, zhStrings.commonJustNow);
    expect(time.fontSize, 11.5);
    expect(time.height, 1);
    expect(time.color, cs.onSurfaceVariant);

    await tester.tap(find.text('標題'));
    await tester.pumpAndSettle();
    final footer = _styleOf(
      tester,
      tester.widgetList<Text>(find.textContaining('發布')).single.data!,
    );
    expect(footer.fontSize, 11.5);
    expect(footer.height, 1);
    expect(footer.color, cs.outline);
  });

  testWidgets('critical row carries a tinted surface and a severity tag', (
    tester,
  ) async {
    await _open(tester, [
      (_tra, _alert('嚴重', level: AlertSeverity.red, source: _tra)),
    ]);
    final cs = _scheme(tester);
    final accent = noticeColors(NoticeTone.critical, cs).accent;

    final surface = tester.widget<Container>(_rowSurface(cs));
    final decoration = surface.decoration! as BoxDecoration;
    expect(
      decoration.color,
      Color.alphaBlend(accent.withValues(alpha: 0.05), cs.surface),
    );

    final tag = find.ancestor(
      of: find.text(zhStrings.alertsDisruption),
      matching: find.byType(Container),
    );
    final tagBox =
        tester.widget<Container>(tag.first).decoration! as BoxDecoration;
    expect((tagBox.border! as Border).top.color, accent.withValues(alpha: 0.4));
    final tagText = _styleOf(tester, zhStrings.alertsDisruption);
    expect(tagText.fontSize, 11.5);
    expect(tagText.color, accent);
  });

  testWidgets('a non-critical row has the plain surface and no tag', (
    tester,
  ) async {
    await _open(tester, [(_tra, _alert('黃色', source: _tra))]);
    final cs = _scheme(tester);

    expect(find.text(zhStrings.alertsDisruption), findsNothing);
    final decoration =
        tester.widget<Container>(_rowSurface(cs)).decoration! as BoxDecoration;
    expect(decoration.color, cs.surface);
  });

  testWidgets('only a critical row with a source gets a gap before the tag', (
    tester,
  ) async {
    await _open(tester, [
      (_tra, _alert('一', level: AlertSeverity.red, source: _tra)),
    ]);
    final criticalWithSource = _gaps(tester);
    await tester.pumpWidget(const SizedBox());

    await _open(tester, [(_tra, _alert('二', level: AlertSeverity.red))]);
    final criticalNoSource = _gaps(tester);
    await tester.pumpWidget(const SizedBox());

    await _open(tester, [(_tra, _alert('三', source: _tra))]);
    final plainWithSource = _gaps(tester);

    expect(criticalWithSource, criticalNoSource + 1);
    expect(criticalWithSource, plainWithSource + 1);
  });

  testWidgets('a title is clamped against the text column, not the row', (
    tester,
  ) async {
    // The sheet is capped at 640 wide, so the column is 640 - 40 - 30 = 570:
    // 38 glyphs of 15px per line, and 80 glyphs need three lines. A column
    // 60px wider (42 per line) would fit them in two.
    await _open(tester, [(_tra, _alert(_run(80), source: _tra))]);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    await _open(tester, [(_tra, _alert(_run(70), source: _tra))]);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
  });

  testWidgets('a body is measured in the body style, a title in its own', (
    tester,
  ) async {
    // 80 glyphs: three lines at 15px (38 per line) but two at 13.5px (42).
    await _open(tester, [(_tra, _alert(_run(80), title: '短', source: _tra))]);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);
  });

  testWidgets('swiping a row reveals the clear icon', (tester) async {
    await _open(tester, [(_tra, _alert('滑掉', source: _tra))]);

    await tester.drag(find.text('滑掉'), const Offset(-200, 0));
    await tester.pump(const Duration(milliseconds: 50));

    final icon = tester.widget<Icon>(find.byIcon(Icons.delete_outline_rounded));
    expect(icon.size, 22);
    await tester.pumpAndSettle();
  });

  testWidgets('an empty inbox shows the icon, title and hint', (tester) async {
    await _open(tester, const []);

    expect(find.text(zhStrings.alertsEmpty), findsOneWidget);
    expect(find.text(zhStrings.alertsEmptyHint), findsOneWidget);
    final icon = tester.widget<Icon>(
      find.byIcon(Icons.notifications_none_rounded),
    );
    expect(icon.size, 44);
  });
}
