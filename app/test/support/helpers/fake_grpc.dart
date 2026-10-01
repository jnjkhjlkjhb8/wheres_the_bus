import 'dart:async';

import 'package:grpc/grpc.dart';

/// A [ResponseStream] test double backed by a plain [Stream], so a fake gRPC
/// service stub can return streaming responses without a real [ClientCall] or
/// channel. The repository only ever treats the result as a `Stream`.
class FakeResponseStream<R> extends StreamView<R> implements ResponseStream<R> {
  FakeResponseStream(super.stream);

  @override
  Future<void> cancel() async {}

  @override
  Future<Map<String, String>> get headers async => const {};

  @override
  Future<Map<String, String>> get trailers async => const {};

  @override
  ResponseFuture<R> get single => throw UnimplementedError();
}

class FakeResponseFuture<R> implements ResponseFuture<R> {
  FakeResponseFuture(this._future);

  final Future<R> _future;

  @override
  Future<S> then<S>(
    FutureOr<S> Function(R value) onValue, {
    Function? onError,
  }) => _future.then(onValue, onError: onError);

  @override
  Future<R> catchError(Function onError, {bool Function(Object error)? test}) =>
      _future.catchError(onError, test: test);

  @override
  Future<R> whenComplete(FutureOr<void> Function() action) =>
      _future.whenComplete(action);

  @override
  Stream<R> asStream() => _future.asStream();

  @override
  Future<R> timeout(
    Duration timeLimit, {
    FutureOr<R> Function()? onTimeout,
  }) => _future.timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<void> cancel() async {}

  @override
  Future<Map<String, String>> get headers async => const {};

  @override
  Future<Map<String, String>> get trailers async => const {};
}
