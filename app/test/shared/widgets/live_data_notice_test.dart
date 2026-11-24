import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/widgets/live_data_notice.dart';

void main() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF3366CC));

  testWidgets('names the gap, explains it, and reloads', (tester) async {
    var reloads = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme),
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Scaffold(
          body: LiveDataNotice(
            title: '收不到即時資料',
            body: '暫時顯示「—」',
            onReload: () => reloads++,
          ),
        ),
      ),
    );

    final title = tester.widget<Text>(find.text('收不到即時資料'));
    expect(title.style?.fontWeight, FontWeight.w600);
    final body = tester.widget<Text>(find.text('暫時顯示「—」'));
    expect(body.style?.color, scheme.onSurfaceVariant);
    final card = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(LiveDataNotice),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = card.decoration! as BoxDecoration;
    expect(decoration.color, scheme.surfaceContainerHighest);
    expect(
      decoration.borderRadius,
      BorderRadius.circular(AppTheme.radiusCard),
    );
    expect(
      tester.getTopLeft(find.text('收不到即時資料')).dx -
          tester.getTopLeft(find.byType(LiveDataNotice)).dx,
      AppTheme.space16,
    );

    final i18n = AppI18n.of(tester.element(find.byType(LiveDataNotice)));
    await tester.tap(find.text(i18n.commonReload));
    expect(reloads, 1);
  });
}
