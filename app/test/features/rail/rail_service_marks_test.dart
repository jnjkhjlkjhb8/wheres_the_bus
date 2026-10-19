import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/assets/remote_assets.dart';
import 'package:wheres_the_bus/core/assets/remote_image.dart';
import 'package:wheres_the_bus/data/models/thsr_models.dart';
import 'package:wheres_the_bus/data/models/tra_models.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_service_marks.dart';

import '../../support/helpers/i18n.dart';
import '../../support/helpers/remote_assets.dart';

TraTimetableItem _tra({
  bool bike = false,
  bool dining = false,
  bool wheelchair = false,
  bool nursing = false,
  bool daily = false,
}) => TraTimetableItem(
  trainNo: '123',
  trainType: '自強',
  departureTime: '08:00',
  arrivalTime: '09:00',
  travelMinutes: 60,
  delayMinutes: 0,
  hasBike: bike,
  hasDiningCar: dining,
  isDisabledFriendly: wheelchair,
  hasBreastfeeding: nursing,
  remark: '',
  runsDaily: daily,
);

ThsrTimetableItem _thsr({required bool overnight}) => ThsrTimetableItem(
  trainNo: '0801',
  departureTime: '23:00',
  arrivalTime: '00:30',
  travelMinutes: 90,
  delayMinutes: 0,
  remark: '',
  isOvernight: overnight,
);

void main() {
  setUp(seedRemoteAssets);

  test('every mark points at its own artwork', () {
    expect(
      {for (final m in RailServiceMark.values) m: m.asset},
      {
        RailServiceMark.wheelchair: 'rails/notes/serve-wheelchair.png',
        RailServiceMark.bike: 'rails/notes/serve-bicy.png',
        RailServiceMark.dining: 'rails/notes/serve-lunchbox.png',
        RailServiceMark.breastfeeding: 'rails/notes/serve-nursingroom.png',
        RailServiceMark.daily: 'rails/notes/serve-everyday.png',
        RailServiceMark.overnight: 'rails/notes/serve-crossday.png',
      },
    );
  });

  test('only the daily mark is kept out of the list row', () {
    expect(RailServiceMark.values.where((m) => !m.showsInList), [
      RailServiceMark.daily,
    ]);
  });

  test('forTra maps each amenity flag to its mark, in display order', () {
    expect(RailServiceMark.forTra(_tra()), isEmpty);
    expect(RailServiceMark.forTra(_tra(wheelchair: true)), [
      RailServiceMark.wheelchair,
    ]);
    expect(RailServiceMark.forTra(_tra(bike: true)), [RailServiceMark.bike]);
    expect(RailServiceMark.forTra(_tra(dining: true)), [
      RailServiceMark.dining,
    ]);
    expect(RailServiceMark.forTra(_tra(nursing: true)), [
      RailServiceMark.breastfeeding,
    ]);
    expect(RailServiceMark.forTra(_tra(daily: true)), [RailServiceMark.daily]);
    expect(
      RailServiceMark.forTra(
        _tra(
          bike: true,
          dining: true,
          wheelchair: true,
          nursing: true,
          daily: true,
        ),
      ),
      [
        RailServiceMark.wheelchair,
        RailServiceMark.bike,
        RailServiceMark.dining,
        RailServiceMark.breastfeeding,
        RailServiceMark.daily,
      ],
    );
  });

  test('forThsr marks only overnight runs', () {
    expect(RailServiceMark.forThsr(_thsr(overnight: false)), isEmpty);
    expect(RailServiceMark.forThsr(_thsr(overnight: true)), [
      RailServiceMark.overnight,
    ]);
  });

  test('labelOf resolves every mark to its localized name', () {
    expect(
      {for (final m in RailServiceMark.values) m: m.labelOf(zhStrings)},
      {
        RailServiceMark.wheelchair: zhStrings.railServiceWheelchair,
        RailServiceMark.bike: zhStrings.railServiceBike,
        RailServiceMark.dining: zhStrings.railServiceDining,
        RailServiceMark.breastfeeding: zhStrings.railServiceNursing,
        RailServiceMark.daily: zhStrings.railServiceDaily,
        RailServiceMark.overnight: zhStrings.railServiceOvernight,
      },
    );
  });

  testWidgets('the row shows at most maxVisible icons and counts the rest', (
    tester,
  ) async {
    await tester.pumpWidget(
      i18nApp(
        const RailServiceMarkRow(
          marks: [
            RailServiceMark.wheelchair,
            RailServiceMark.bike,
            RailServiceMark.dining,
            RailServiceMark.breastfeeding,
            RailServiceMark.daily,
          ],
        ),
      ),
    );
    expect(find.byType(Image), findsNWidgets(3));
    expect(find.text('+1'), findsOneWidget);
    expect(tester.getSize(find.byType(RemoteImage).first), const Size(14, 14));
  });

  testWidgets('no overflow counter when everything fits', (tester) async {
    await tester.pumpWidget(
      i18nApp(
        const RailServiceMarkRow(
          marks: [RailServiceMark.wheelchair, RailServiceMark.daily],
        ),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('+'), findsNothing);
  });

  testWidgets('a row with nothing list-visible renders nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      i18nApp(const RailServiceMarkRow(marks: [RailServiceMark.daily])),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.byType(Semantics), findsWidgets);
  });

  testWidgets('chips render every mark, daily included, at 20x20', (
    tester,
  ) async {
    await tester.pumpWidget(
      i18nApp(
        const RailServiceMarkChips(
          marks: [RailServiceMark.bike, RailServiceMark.daily],
        ),
      ),
    );
    expect(find.byType(Image), findsNWidgets(2));
    for (final slot in find.byType(RemoteImage).evaluate()) {
      expect(tester.getSize(find.byWidget(slot.widget)), const Size(20, 20));
    }
  });

  testWidgets('a mark whose file has not arrived keeps its slot empty', (
    tester,
  ) async {
    RemoteAssets.instance.debugSeed(Directory.systemTemp, const {});
    await tester.pumpWidget(
      i18nApp(const RailServiceMarkChips(marks: [RailServiceMark.bike])),
    );
    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(RemoteImage)), const Size(20, 20));
  });
}
