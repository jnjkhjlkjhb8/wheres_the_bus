import 'dart:math' as math;

class ShakeRecognizer {
  ShakeRecognizer({
    this.threshold = 15,
    this.requiredReversals = 3,
    this.window = const Duration(milliseconds: 700),
    this.cooldown = const Duration(seconds: 3),
  });

  /// Peak user acceleration (m/s², gravity already excluded by the platform)
  /// a sample must reach to count as one leg of a shake. ~1.5 g: a hand swing
  /// clears it without effort, a vehicle over a joint or a pothole does not.
  final double threshold;

  /// Reversals required inside [window]. Three means the phone travelled
  /// out-back-out — a single knock and its rebound is only one.
  final int requiredReversals;

  /// How long a partial shake stays live. A peak arriving later than this
  /// starts a fresh attempt instead of extending the old one, so slow
  /// unrelated jolts minutes apart can never accumulate into a trigger.
  final Duration window;

  /// Silence after firing, so one long enthusiastic shake asks once.
  final Duration cooldown;

  /// Unit vector of the attempt's first peak. Later peaks are projected onto
  /// it: a shake is one motion back and forth, not force from every side.
  double _axisX = 0;
  double _axisY = 0;
  double _axisZ = 0;

  /// Sign of the last accepted peak along the axis; 0 when no attempt is live.
  int _sign = 0;
  int _reversals = 0;
  Duration _attemptStart = Duration.zero;
  Duration? _firedAt;

  /// Feeds one sample in. Returns true on the sample that completes a shake.
  bool add({
    required double x,
    required double y,
    required double z,
    required Duration at,
  }) {
    final firedAt = _firedAt;
    if (firedAt != null && at - firedAt < cooldown) return false;

    final magnitude = math.sqrt(x * x + y * y + z * z);
    if (magnitude < threshold) return false;

    if (_sign == 0 || at - _attemptStart > window) {
      _axisX = x / magnitude;
      _axisY = y / magnitude;
      _axisZ = z / magnitude;
      _sign = 1;
      _reversals = 0;
      _attemptStart = at;
      return false;
    }

    final projection = x * _axisX + y * _axisY + z * _axisZ;
    // A peak perpendicular to the axis projects to near zero, where the sign
    // is noise rather than a direction. Half the threshold is the point past
    // which the sample is plainly travelling along the shake, not across it.
    if (projection.abs() < threshold / 2) return false;
    final sign = projection >= 0 ? 1 : -1;
    if (sign == _sign) return false;

    _sign = sign;
    _reversals++;
    if (_reversals < requiredReversals) return false;

    _firedAt = at;
    _sign = 0;
    _reversals = 0;
    return true;
  }

  /// Drops any half-finished attempt. Called when the stream is paused, so a
  /// shake cannot be assembled from peaks either side of a gap.
  void reset() {
    _sign = 0;
    _reversals = 0;
  }
}
