sealed class EtaStatus {
  const EtaStatus();
  factory EtaStatus.arriving() = EtaArriving;
  factory EtaStatus.approaching() = EtaApproaching;
  factory EtaStatus.minutes(int m) = EtaMinutes;
  factory EtaStatus.minutesSeconds(int m, int s) = EtaMinutesSeconds;
  factory EtaStatus.label(String text) = EtaLabel;
  factory EtaStatus.unknown() = EtaUnknown;
}

final class EtaArriving extends EtaStatus {
  const EtaArriving();
}

final class EtaApproaching extends EtaStatus {
  const EtaApproaching();
}

final class EtaMinutes extends EtaStatus {
  const EtaMinutes(this.value);
  final int value;
}

/// A minute + second countdown (捷運: 3分45秒). Metro carries second precision
/// and decays locally between server frames, so it needs the finer display.
final class EtaMinutesSeconds extends EtaStatus {
  const EtaMinutesSeconds(this.minutes, this.seconds);
  final int minutes;
  final int seconds;
}

/// A service-state label (e.g. 尚未發車, 末班已過, or a scheduled clock time)
/// carried verbatim from the one status-label mapping in eta_format.dart.
final class EtaLabel extends EtaStatus {
  const EtaLabel(this.text);
  final String text;
}

final class EtaUnknown extends EtaStatus {
  const EtaUnknown();
}
