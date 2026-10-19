import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/features/favorites/view/favorites_screen.dart';

import '../../support/helpers/i18n.dart';

class _Repo implements FavoritesRepository {
  _Repo(this.items);

  final List<Favorite> items;
  final removed = <String>[];
  final pins = <(String, bool)>[];

  @override
  bool get isReady => true;

  @override
  List<Favorite> all() => items;

  @override
  Stream<void> changes() => const Stream.empty();

  @override
  Future<void> remove(String id) async => removed.add(id);

  @override
  Future<void> setPinned(String id, {required bool pinned}) async =>
      pins.add((id, pinned));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

const _fav = Favorite(type: FavoriteType.busStop, refId: '1', title: '站牌');

Future<List<String>> _pump(WidgetTester tester, _Repo repo) async {
  final haptics = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  final bloc = FavoritesBloc(repo, ValueNotifier(true));
  addTearDown(bloc.close);
  await tester.pumpWidget(
    i18nApp(BlocProvider.value(value: bloc, child: const FavoritesScreen())),
  );
  await tester.pumpAndSettle();
  return haptics;
}

void main() {
  testWidgets('the populated list is keyed, the empty state is not', (
    tester,
  ) async {
    await _pump(tester, _Repo([]));
    expect(find.byKey(const ValueKey('favorites-list')), findsNothing);
    await _pump(tester, _Repo([_fav]));
    expect(find.byKey(const ValueKey('favorites-list')), findsOneWidget);
  });

  testWidgets('rows are split by a 0.5px hairline at 30% outline', (
    tester,
  ) async {
    await _pump(tester, _Repo([_fav]));
    final cs = Theme.of(
      tester.element(find.byType(FavoritesScreen)),
    ).colorScheme;
    final hairline = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((d) => d.decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.border)
        .whereType<Border>()
        .map((b) => b.bottom)
        .where((s) => s.width == 0.5);
    expect(hairline.single.color, cs.outlineVariant.withValues(alpha: 0.3));
  });

  testWidgets('the empty hint is set at 1.5 line height', (tester) async {
    await _pump(tester, _Repo([]));
    final hint = tester.widget<Text>(find.text(zhStrings.favoritesEmptyHint));
    expect(hint.style!.height, 1.5);
  });

  testWidgets('swiping a row away taps haptics and removes the favorite', (
    tester,
  ) async {
    final repo = _Repo([_fav]);
    final haptics = await _pump(tester, repo);
    await tester.drag(
      find.byKey(ValueKey('dismiss-${_fav.id}')),
      const Offset(-650, 0),
    );
    await tester.pumpAndSettle();
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    expect(repo.removed, [_fav.id]);
    expect(find.text(zhStrings.favoritesRemoved), findsOneWidget);
  });

  testWidgets('the pin button taps haptics and flips the pin', (tester) async {
    final repo = _Repo([_fav]);
    final haptics = await _pump(tester, repo);
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    expect(repo.pins, [(_fav.id, true)]);
  });
}
