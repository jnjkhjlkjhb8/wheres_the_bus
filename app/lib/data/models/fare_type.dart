import 'package:wheres_the_bus/l10n/app_i18n.dart';

enum FareType {
  full('full'),
  student('student'),
  child('child'),
  concession('concession');

  const FareType(this.key);

  /// Value persisted through `SettingsRepository.fareType`.
  final String key;

  static FareType fromKey(String? key) =>
      values.firstWhere((e) => e.key == key, orElse: () => full);

  /// Display name — the option label in Settings and the heading every quoted
  /// fare is labelled with.
  String labelOf(AppI18n i18n) => switch (this) {
    FareType.full => i18n.fareFull,
    FareType.student => i18n.fareStudent,
    FareType.child => i18n.fareChild,
    FareType.concession => i18n.fareConcession,
  };

  List<String> get traPrefixes => switch (this) {
    FareType.full || FareType.student => const ['成'],
    FareType.child => const ['孩', '成'],
    FareType.concession => const ['敬', '愛', '成'],
  };

  /// THSR fare classes to try, in order: 1 全票, 9 半票. THSR charges 孩童,
  /// 敬老 and 愛心 the same 半票, so all three collapse to one class.
  List<int> get thsrFareClasses => switch (this) {
    FareType.full || FareType.student => const [1],
    FareType.child || FareType.concession => const [9, 1],
  };

  /// TDX bus FareClass codes to try, in order (see the enum in
  /// `fare_decoder.dart`). Concession walks 敬老 → 愛心 → 半票 because operators
  /// publish the same price under any of the three.
  List<int> get busFareClasses => switch (this) {
    FareType.full => const [1],
    FareType.student => const [2, 1],
    FareType.child => const [7, 10, 1],
    FareType.concession => const [3, 4, 10, 1],
  };

  FareType matchedWhen({required bool isFullFare}) =>
      isFullFare ? FareType.full : this;
}

typedef ResolvedFare = ({int price, FareType matched});
