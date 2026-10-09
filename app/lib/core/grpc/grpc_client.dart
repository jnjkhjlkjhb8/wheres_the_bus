import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/grpc/grpc_compression_interceptor.dart';
import 'package:wheres_the_bus/core/grpc/grpc_deadline_interceptor.dart';
import 'package:wheres_the_bus/core/grpc/grpc_error_interceptor.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/data/generated/alert.pbgrpc.dart';
import 'package:wheres_the_bus/data/generated/bike.pbgrpc.dart';
import 'package:wheres_the_bus/data/generated/bus.pbgrpc.dart';
import 'package:wheres_the_bus/data/generated/feedback.pbgrpc.dart';
import 'package:wheres_the_bus/data/generated/firebase.pbgrpc.dart';
import 'package:wheres_the_bus/data/generated/maas.pbgrpc.dart';
import 'package:wheres_the_bus/data/generated/mrt.pbgrpc.dart';
import 'package:wheres_the_bus/data/generated/near.pbgrpc.dart';
import 'package:wheres_the_bus/data/generated/thsr.pbgrpc.dart';
import 'package:wheres_the_bus/data/generated/tra.pbgrpc.dart';

class GrpcClient {
  GrpcClient._();
  static final GrpcClient instance = GrpcClient._();
  static const _host = String.fromEnvironment(
    'GRPC_HOST',
    defaultValue: '127.0.0.1',
  );
  static const _port = int.fromEnvironment('GRPC_PORT', defaultValue: 50051);
  static const _tls = bool.fromEnvironment('GRPC_TLS');
  // No defaultValue on purpose: an unset APP_ENV must land in the strict
  // branch of validateConfig below, not silently masquerade as 'dev'.
  static const _appEnv = String.fromEnvironment('APP_ENV');
  static bool _configValidated = false;

  static void validateConfig({
    required String appEnv,
    required String host,
    required bool tls,
  }) {
    final isLocalEnv = appEnv == 'dev' || appEnv == 'test';
    if (isLocalEnv) return;
    if (host.isEmpty || host == 'localhost' || host == '127.0.0.1') {
      throw StateError(
        'GRPC_HOST must be a non-loopback host in the "$appEnv" environment',
      );
    }
    if (!tls) {
      throw StateError('GRPC_TLS must be true in the "$appEnv" environment');
    }
  }

  static Future<void> init() async {
    validateConfig(appEnv: _appEnv, host: _host, tls: _tls);
    _configValidated = true;
    _observeForeground();
    warmConnection();
  }

  static bool _observingForeground = false;

  static void _observeForeground() {
    if (_observingForeground) return;
    _observingForeground = true;
    AppForeground.value.addListener(handleForeground);
  }

  @visibleForTesting
  static void handleForeground() {
    if (!AppForeground.value.value) return;
    instance.recycle();
    warmConnection();
  }

  static void warmConnection() {
    instance._channel.getConnection().ignore();
  }

  ClientChannel? _channelInstance;

  ClientChannel get _channel => _channelInstance ??= _buildChannel();

  /// Drops the current channel so the next RPC builds a fresh one. In-flight
  /// calls are terminated rather than drained: this runs when the transport
  /// underneath is already known to be gone.
  void recycle() {
    final old = _channelInstance;
    _channelInstance = null;
    old?.terminate().ignore();
  }

  /// How many channels this client has built. Lets a test tell a recycle from
  /// a channel that was merely reused.
  @visibleForTesting
  int channelGeneration = 0;

  ClientChannel _buildChannel() {
    channelGeneration++;
    if (_tls && !_configValidated) {
      throw StateError(
        'GrpcClient.init() must complete successfully before the channel '
        'is used when GRPC_TLS is enabled',
      );
    }
    return ClientChannel(
      _host,
      port: _port,
      options: ChannelOptions(
        credentials: _tls
            ? const ChannelCredentials.secure()
            : const ChannelCredentials.insecure(),
        keepAlive: const ClientKeepAliveOptions(
          pingInterval: Duration(seconds: 60),
          timeout: Duration(seconds: 10),
        ),
        // A connect attempt against an unreachable host must fail on a
        // human timescale rather than sit on the OS default.
        connectTimeout: const Duration(seconds: 10),
        codecRegistry: CodecRegistry(
          codecs: const [GzipCodec(), IdentityCodec()],
        ),
      ),
    );
  }

  static final List<ClientInterceptor> _interceptors = [
    GrpcCompressionInterceptor(),
    GrpcDeadlineInterceptor(),
    GrpcErrorInterceptor(),
  ];

  Bus_Route_ServiceClient get busRoute =>
      Bus_Route_ServiceClient(_channel, interceptors: _interceptors);
  Bus_Station_ServiceClient get busStation =>
      Bus_Station_ServiceClient(_channel, interceptors: _interceptors);
  Bike_ServiceClient get bike =>
      Bike_ServiceClient(_channel, interceptors: _interceptors);
  Mrt_ServiceClient get mrt =>
      Mrt_ServiceClient(_channel, interceptors: _interceptors);
  TRA_timetable_serviceClient get traTimetable =>
      TRA_timetable_serviceClient(_channel, interceptors: _interceptors);
  TRA_Detain_serviceClient get traDetain =>
      TRA_Detain_serviceClient(_channel, interceptors: _interceptors);
  Thsr_timetable_serviceClient get thsr =>
      Thsr_timetable_serviceClient(_channel, interceptors: _interceptors);
  Thsr_Detain_serviceClient get thsrDetain =>
      Thsr_Detain_serviceClient(_channel, interceptors: _interceptors);
  Alert_ServiceClient get alert =>
      Alert_ServiceClient(_channel, interceptors: _interceptors);
  Near_Station_ServiceClient get near =>
      Near_Station_ServiceClient(_channel, interceptors: _interceptors);
  MaasServiceClient get maas =>
      MaasServiceClient(_channel, interceptors: _interceptors);
  Firebase_ServiceClient get firebase =>
      Firebase_ServiceClient(_channel, interceptors: _interceptors);
  Feedback_ServiceClient get feedback =>
      Feedback_ServiceClient(_channel, interceptors: _interceptors);

  Future<void> shutdown() async {
    final old = _channelInstance;
    _channelInstance = null;
    await old?.shutdown();
  }
}
