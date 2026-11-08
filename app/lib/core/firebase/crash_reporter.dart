import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';

class CrashReporter {
  CrashReporter._();

  /// Records [error] unless it is an outcome the app already handles:
  /// reporting offline, timeout and not-found results buried the real defects
  /// under reconnect noise.
  static void record(
    Object error, [
    StackTrace? stack,
  ]) {
    if (AppError.from(error).reportable) {
      sink(error, stack);
    }
  }

  /// Where [record] sends a report. [FirebaseGate.enabled] is a compile-time
  /// constant that is off under `flutter test`, so tests replace this to see
  /// what [record] lets through.
  @visibleForTesting
  static void Function(Object error, StackTrace? stack) sink = _crashlytics;

  static void _crashlytics(Object error, StackTrace? stack) {
    if (!_firebaseReady) return;
    FirebaseCrashlytics.instance.recordError(error, stack).ignore();
  }

  static bool get _firebaseReady =>
      Firebase.apps.isNotEmpty && FirebaseGate.enabled;
}
