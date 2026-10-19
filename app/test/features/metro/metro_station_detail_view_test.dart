import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';
import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';
import 'package:wheres_the_bus/features/metro/view/metro_station_detail_view.dart';
import 'package:wheres_the_bus/shared/widgets/bottom_sheet_shell.dart';
import '../../support/metro_station_harness.dart';

class _QuietRepository extends MrtRepository {
  @override
  Stream<MetroLiveArrival> eta(String system, String stationId) =>
      const Stream.empty();

  @override
  Future<List<MetroScheduleEntry>> schedule(
    String system,
    String stationId,
  ) async => const [];
}

void main() {
  Future<void> pump(WidgetTester tester, {VoidCallback? onClose}) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpWithMetroProviders(
      tester,
      MetroStationDetailView(
        system: 'TRTC',
        stationId: 'BL12',
        name: '台北車站',
        onClose: onClose,
        repository: _QuietRepository(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('embedded in a sheet it brings its own drag handle', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
    expect(find.byType(SheetDragHandle), findsOneWidget);
    expect(find.text('台北車站'), findsWidgets);
  });

  testWidgets('with an owner callback the host supplies the handle', (
    tester,
  ) async {
    await pump(tester, onClose: () {});
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsNothing);
    expect(find.byType(SheetDragHandle), findsNothing);
    expect(find.text('台北車站'), findsWidgets);
  });
}
