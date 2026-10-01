import 'package:grpc/grpc.dart';

class GrpcCompressionInterceptor extends ClientInterceptor {
  GrpcCompressionInterceptor();

  static const _gzip = GzipCodec();

  // A call site that picked its own codec wins, same as the deadline
  // interceptor: `mergedWith` takes the argument's compression first.
  CallOptions _gzipped(CallOptions options) =>
      CallOptions(compression: _gzip).mergedWith(options);

  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) => invoker(method, request, _gzipped(options));

  @override
  ResponseStream<R> interceptStreaming<Q, R>(
    ClientMethod<Q, R> method,
    Stream<Q> requests,
    CallOptions options,
    ClientStreamingInvoker<Q, R> invoker,
  ) => invoker(method, requests, _gzipped(options));
}
