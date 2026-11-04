import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:protobuf/protobuf.dart';

/// The field the server sets on its idle heartbeat frame; every
/// server-streaming response reserves it in models/*.proto. The frame keeps a
/// silent stream alive through Cloudflare's ~100s idle cut and carries no
/// data, so it is dropped before any listener sees it.
const streamHeartbeatField = 1000;

/// Whether [message] is the server's heartbeat frame rather than data. A plain
/// empty message is data: near and alert streams send those on purpose.
bool isStreamHeartbeat(Object? message) =>
    message is GeneratedMessage &&
    message.unknownFields.hasField(streamHeartbeatField);

class GrpcHeartbeatInterceptor extends ClientInterceptor {
  @override
  ResponseStream<R> interceptStreaming<Q, R>(
    ClientMethod<Q, R> method,
    Stream<Q> requests,
    CallOptions options,
    ClientStreamingInvoker<Q, R> invoker,
  ) => _HeartbeatFilteredStream(invoker(method, requests, options));
}

class _HeartbeatFilteredStream<R> extends StreamView<R>
    implements ResponseStream<R> {
  _HeartbeatFilteredStream(this._inner)
    : super(_inner.where((message) => !isStreamHeartbeat(message)));

  final ResponseStream<R> _inner;

  @override
  Future<void> cancel() => _inner.cancel();

  @override
  Future<Map<String, String>> get headers => _inner.headers;

  @override
  Future<Map<String, String>> get trailers => _inner.trailers;

  @override
  ResponseFuture<R> get single => _inner.single;
}
