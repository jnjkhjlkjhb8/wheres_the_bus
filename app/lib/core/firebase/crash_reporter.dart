import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';

class CrashReporter {
  CrashReporter._();

  static void record(
    Object error, [
    StackTrace? stack,
  ]) {
    if (!FirebaseGate.enabled || Firebase.apps.isEmpty) return;
    FirebaseCrashlytics.instance.recordError(error, stack).ignore();
  }
}
