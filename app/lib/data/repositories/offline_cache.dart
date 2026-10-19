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
  final fresh = maxAge == null ? null : HiveStore.getStaticFresh(key, maxAge);
  final cached = _decodeCached(key, fresh, parse, decode);
  if (cached != null) return cached.value;
  final offline = _offlineValue(key, parse, decode);
  if (offline != null) return offline.value;
  return _fetchWithFallback(key, fetch, parse, decode);
}

({T value})? _offlineValue<M extends GeneratedMessage, T>(
  String key,
  M Function(List<int>) parse,
  T Function(M) decode,
) {
  if (AppNetwork.online.value) return null;
  return _decodeCached(key, HiveStore.getStatic(key), parse, decode);
}

({T value})? _decodeCached<M extends GeneratedMessage, T>(
  String key,
  List<int>? bytes,
  M Function(List<int>) parse,
  T Function(M) decode,
) {
  if (bytes == null) return null;
  try {
    return (value: decode(parse(bytes)));
  } on Object {
    // Old or corrupt bytes must not block a fresh request or replace its error.
    unawaited(HiveStore.deleteStatic(key));
    return null;
  }
}

Future<T> _fetchWithFallback<M extends GeneratedMessage, T>(
  String key,
  Future<M> Function() fetch,
  M Function(List<int>) parse,
  T Function(M) decode,
) async {
  try {
    final message = await fetch();
    // Unawaited: a full disk must not fail a request that already succeeded.
    unawaited(HiveStore.putStatic(key, message.writeToBuffer()));
    return decode(message);
  } on Object catch (error, stack) {
    if (!_isReachabilityFailure(error)) rethrow;
    final cached = _decodeCached(key, HiveStore.getStatic(key), parse, decode);
    if (cached != null) return cached.value;
    Error.throwWithStackTrace(error, stack);
  }
}

/// Only an unreachable server justifies serving a cached answer. A `NotFound`
/// or a server-side error means the backend *did* reply, and overriding a
/// definitive answer with a stale one would be a worse lie than the error.
bool _isReachabilityFailure(Object error) => switch (AppError.from(error)) {
  OfflineError() || TimeoutError() => true,
  _ => false,
};
