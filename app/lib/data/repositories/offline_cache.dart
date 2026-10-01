import 'dart:async';

import 'package:protobuf/protobuf.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';
import 'package:wheres_the_bus/core/storage/hive_store.dart';

Future<T> offlineCached<M extends GeneratedMessage, T>({
  required String key,
  required Future<M> Function() fetch,
  required M Function(List<int>) parse,
  required T Function(M) decode,
  Duration? maxAge,
}) async {
  if (maxAge != null) {
    final fresh = HiveStore.getStaticFresh(key, maxAge);
    if (fresh != null) {
      try {
        return decode(parse(fresh));
      } on Object {
        // Bytes an older build wrote in a shape this one cannot read. Drop
        // them and fall through to the network — unlike the offline branch
        // below there is a live request available, so nothing is lost.
        unawaited(HiveStore.deleteStatic(key));
      }
    }
  }
  if (!AppNetwork.online.value) {
    final bytes = HiveStore.getStatic(key);
    if (bytes != null) {
      try {
        return decode(parse(bytes));
      } on Object {
        unawaited(HiveStore.deleteStatic(key));
      }
    }
  }
  try {
    final message = await fetch();
    // Unawaited: a full disk must not fail a request that already succeeded.
    unawaited(HiveStore.putStatic(key, message.writeToBuffer()));
    return decode(message);
  } on Object catch (error, stack) {
    if (!_isReachabilityFailure(error)) rethrow;
    final bytes = HiveStore.getStatic(key);
    if (bytes == null) rethrow;
    try {
      return decode(parse(bytes));
    } on Object {
      unawaited(HiveStore.deleteStatic(key));
      Error.throwWithStackTrace(error, stack);
    }
  }
}

/// Only an unreachable server justifies serving a cached answer. A `NotFound`
/// or a server-side error means the backend *did* reply, and overriding a
/// definitive answer with a stale one would be a worse lie than the error.
bool _isReachabilityFailure(Object error) => switch (AppError.from(error)) {
  OfflineError() || TimeoutError() => true,
  _ => false,
};
