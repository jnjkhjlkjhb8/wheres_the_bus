import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/shared/widgets/sheet_detail_header.dart';

import '../../support/helpers/i18n.dart';

void main() {
  testWidgets('favorite toggles publish saved state and undo reverses it', (
    tester,
  ) async {
    final ready = ValueNotifier(true);
    final repository = _FavoritesMemory();
    final bloc = FavoritesBloc(repository, ready);
    addTearDown(bloc.close);
    addTearDown(repository.changed.close);
    addTearDown(ready.dispose);
    const favorite = Favorite(
      type: FavoriteType.metroStation,
      refId: 'TRTC:BL01',
      title: '頂埔',
    );
    final toggled = <bool>[];
    await tester.pumpWidget(
      i18nApp(
        BlocProvider.value(
          value: bloc,
          child: Scaffold(
            body: FavoriteToggleButton(
              favorite: favorite,
              onToggled: toggled.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.bookmark_border_rounded));
    await tester.pumpAndSettle();
    expect(repository.items.containsKey(favorite.id), isTrue);
    expect(find.byIcon(Icons.bookmark_rounded), findsOneWidget);
    expect(toggled, [true]);
    expect(find.text(zhStrings.favoriteAdded), findsOneWidget);
    await tester.tap(find.text(zhStrings.commonUndo));
    await tester.pumpAndSettle();
    expect(repository.items.containsKey(favorite.id), isFalse);
    expect(find.byIcon(Icons.bookmark_border_rounded), findsOneWidget);
    expect(toggled, [true, false]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('only a header given a favorite offers the bookmark', (
    tester,
  ) async {
    final ready = ValueNotifier(true);
    final repository = _FavoritesMemory();
    final bloc = FavoritesBloc(repository, ready);
    addTearDown(bloc.close);
    addTearDown(repository.changed.close);
    addTearDown(ready.dispose);

    Future<void> pump(Favorite? favorite) => tester.pumpWidget(
      i18nApp(
        BlocProvider.value(
          value: bloc,
          child: Scaffold(
            body: SheetDetailHeader(title: '頂埔', favorite: favorite),
          ),
        ),
      ),
    );

    await pump(null);
    expect(find.byType(FavoriteToggleButton), findsNothing);

    await pump(
      const Favorite(
        type: FavoriteType.metroStation,
        refId: 'TRTC:BL01',
        title: '頂埔',
      ),
    );
    expect(find.byType(FavoriteToggleButton), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _FavoritesMemory implements FavoritesRepository {
  final items = <String, Favorite>{};
  final changed = StreamController<void>.broadcast();

  @override
  List<Favorite> all() => items.values.toList();

  @override
  Stream<void> changes() => changed.stream;

  @override
  Stream<BoxEvent> watch() => const Stream.empty();

  @override
  Future<bool> toggle(Favorite favorite) async {
    final removed = items.remove(favorite.id);
    if (removed == null) items[favorite.id] = favorite;
    changed.add(null);
    return removed == null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
