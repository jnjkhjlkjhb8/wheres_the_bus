import 'package:grpc/grpc.dart';

class GrpcDeadlineInterceptor extends ClientInterceptor {
  GrpcDeadlineInterceptor({
    this.defaultTimeout = const Duration(seconds: 10),
  });

  final Duration defaultTimeout;

  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    final withDeadline = options.timeout != null
        ? options
        : CallOptions(timeout: defaultTimeout).mergedWith(options);
    return invoker(method, request, withDeadline);
  }
}
