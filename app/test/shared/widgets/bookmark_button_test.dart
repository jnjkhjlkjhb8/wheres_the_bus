import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:wheres_the_bus/data/models/favorite.dart';
import 'package:wheres_the_bus/data/repositories/favorites_repository.dart';
import 'package:wheres_the_bus/features/favorites/bloc/favorites_bloc.dart';
import 'package:wheres_the_bus/shared/widgets/bookmark_button.dart';

import '../../support/helpers/i18n.dart';

Future<_Memory> _tapBookmark(
  WidgetTester tester, {
  required String routeType,
}) async {
  final ready = ValueNotifier(true);
  final repository = _Memory();
  final bloc = FavoritesBloc(repository, ready);
  addTearDown(bloc.close);
  addTearDown(repository.changed.close);
  addTearDown(ready.dispose);
  await tester.pumpWidget(
    i18nApp(
      BlocProvider.value(
        value: bloc,
        child: Scaffold(
          body: BookmarkButton(
            routeType: routeType,
            routeKey: 'K1',
            routeLabel: 'Label',
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byIcon(Icons.bookmark_border_rounded));
  await tester.pumpAndSettle();
  await tester.pumpWidget(const SizedBox.shrink());
  return repository;
}

void main() {
  testWidgets('bus route saves as a busRoute without subtitle', (tester) async {
    final repo = await _tapBookmark(tester, routeType: 'bus');
    final saved = repo.items.values.single;
    expect(saved.type, FavoriteType.busRoute);
    expect(saved.refId, 'K1');
    expect(saved.title, 'Label');
    expect(saved.subtitle, isEmpty);
  });

  testWidgets('rail route saves as a railTrain carrying the system label', (
    tester,
  ) async {
    final repo = await _tapBookmark(tester, routeType: '台鐵');
    final saved = repo.items.values.single;
    expect(saved.type, FavoriteType.railTrain);
    expect(saved.subtitle, '台鐵');
  });
}

class _Memory implements FavoritesRepository {
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
