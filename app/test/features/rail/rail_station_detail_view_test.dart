import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/rail_station_board.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_bloc.dart';
import 'package:wheres_the_bus/features/rail/bloc/rail_station_board_event.dart';
import 'package:wheres_the_bus/features/rail/view/rail_station_detail_view.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';

import '../../support/rail_station_fakes.dart';

void main() {
  Future<RailStationBoardBloc> pumpDetail(
    WidgetTester tester,
    RailSystem system,
  ) async {
    final bloc = RailStationBoardBloc(
      system: system,
      stationId: '1000',
      traRepository: BoardTraRepository(),
      thsrRepository: BoardThsrRepository(),
      clock: () => DateTime(2026, 7, 29, 14, 29),
    )..add(const RailStationBoardRequested(RailBoardDirection.forward));
    addTearDown(bloc.close);
    await pumpRailHost(
      tester,
      RailStationDetailView(
        system: system,
        stationId: '1000',
        name: '台北車站',
        bloc: bloc,
      ),
    );
    await tester.pumpAndSettle();
    return bloc;
  }

  Map<RailBoardDirection, String> options(WidgetTester tester) => tester
      .widget<AppSlidingSegment<RailBoardDirection>>(
        find.byType(AppSlidingSegment<RailBoardDirection>),
      )
      .options;

  testWidgets('TRA names its directions in the operator wording', (
    tester,
  ) async {
    await pumpDetail(tester, RailSystem.tra);
    expect(options(tester), {
      RailBoardDirection.forward: '順行',
      RailBoardDirection.reverse: '逆行',
    });
    expect(find.text('台鐵 · 站別發車看板'), findsOneWidget);
  });

  testWidgets('THSR names its directions in the operator wording', (
    tester,
  ) async {
    await pumpDetail(tester, RailSystem.thsr);
    expect(options(tester), {
      RailBoardDirection.forward: '南下',
      RailBoardDirection.reverse: '北上',
    });
    expect(find.text('高鐵 · 站別發車看板'), findsOneWidget);
  });

  testWidgets('the segment moves as soon as a direction is requested', (
    tester,
  ) async {
    final repo = BoardTraRepository();
    final bloc = RailStationBoardBloc(
      system: RailSystem.tra,
      stationId: '1000',
      traRepository: repo,
      thsrRepository: BoardThsrRepository(),
      clock: () => DateTime(2026, 7, 29, 14, 29),
    )..add(const RailStationBoardRequested(RailBoardDirection.forward));
    addTearDown(bloc.close);
    await pumpRailHost(
      tester,
      RailStationDetailView(
        system: RailSystem.tra,
        stationId: '1000',
        name: '台北車站',
        bloc: bloc,
      ),
    );
    await tester.pumpAndSettle();
    AppSlidingSegment<RailBoardDirection> segment() =>
        tester.widget<AppSlidingSegment<RailBoardDirection>>(
          find.byType(AppSlidingSegment<RailBoardDirection>),
        );
    expect(segment().value, RailBoardDirection.forward);

    // Held in flight: the segment must not wait for the board to land.
    final inFlight = Completer<void>();
    repo.gate = inFlight.future;
    try {
      bloc.add(const RailStationBoardRequested(RailBoardDirection.reverse));
      await tester.pump();
      await tester.pump();
      expect(segment().value, RailBoardDirection.reverse);
    } finally {
      // Bloc.close waits on this fetch and nothing pumps during teardown, so a
      // failing expectation above must still let it land.
      inFlight.complete();
      await tester.pumpAndSettle();
    }
    expect(segment().value, RailBoardDirection.reverse);
  });

  testWidgets('without an injected bloc it opens on the forward direction', (
    tester,
  ) async {
    final repo = BoardTraRepository(gate: Completer<void>().future);
    await pumpRailHost(
      tester,
      RailStationDetailView(
        system: RailSystem.tra,
        stationId: '1000',
        name: '台北車站',
        traRepository: repo,
        thsrRepository: BoardThsrRepository(),
      ),
    );
    await tester.pump();
    final segment = tester.widget<AppSlidingSegment<RailBoardDirection>>(
      find.byType(AppSlidingSegment<RailBoardDirection>),
    );
    expect(segment.value, RailBoardDirection.forward);
  });
}
