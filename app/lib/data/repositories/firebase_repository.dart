import 'package:fixnum/fixnum.dart';
import 'package:flutter/foundation.dart';
import 'package:wheres_the_bus/core/firebase/firebase_call_options.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/firebase/install_identity.dart';
import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/data/decoders/firebase_decoder.dart';
import 'package:wheres_the_bus/data/generated/firebase.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/firebase_models.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';

/// The platform string the server and the `firebase_device` CHECK constraint
/// accept. `TargetPlatform.iOS.name` is `'iOS'`, which both reject, so the
/// value is always lowercased before it leaves the app.
String devicePlatform() => defaultTargetPlatform.name.toLowerCase();

bool isArrivalReminderRouteType(String value) =>
    value == 'bus' || value == 'tra' || value == 'thsr';

class FirebaseRepository {
  FirebaseRepository({
    Firebase_ServiceClient? client,
    SettingsRepository? settings,
  }) : _client = client,
       _settings = settings ?? SettingsRepository.instance;

  static final instance = FirebaseRepository();

  final Firebase_ServiceClient? _client;
  Firebase_ServiceClient get _grpc => _client ?? GrpcClient.instance.firebase;

  final SettingsRepository _settings;

  Future<FirebaseDeviceState> upsertDevice({required String fcmToken}) async {
    if (!FirebaseGate.enabled) return const FirebaseDeviceState();
    final installId = await InstallIdentity.getOrCreate();
    final state = await _grpc.upsertDevice(
      UpsertDeviceRequest(
        identity: DeviceIdentity(
          installId: installId,
          fcmToken: fcmToken,
          platform: devicePlatform(),
          appVersion: const String.fromEnvironment(
            'APP_VERSION',
            defaultValue: '1.0.0',
          ),
        ),
        prefs: DevicePrefs(pushEnabled: _settings.pushEnabled),
      ),
      options: await FirebaseCallOptions.build(),
    );
    return FirebaseDecoder.instance.decodeDeviceState(state);
  }

  Future<FirebaseAck> replaceRouteSubscriptions(Set<String> scope) async {
    if (!FirebaseGate.enabled) {
      return const FirebaseAck(ok: true, message: 'disabled');
    }
    final ack = await _grpc.replaceRouteSubscriptions(
      RouteSubscriptionsRequest(
        installId: await InstallIdentity.getOrCreate(),
        subscriptions: [
          for (final entry in scope)
            RouteSubscription(
              routeType: entry.substring(0, entry.indexOf(':')),
              routeKey: entry.substring(entry.indexOf(':') + 1),
            ),
        ],
      ),
      options: await FirebaseCallOptions.build(),
    );
    return FirebaseDecoder.instance.decodeAck(ack);
  }

  Future<ArrivalReminderReceipt> createArrivalReminder({
    required String routeType,
    required String routeKey,
    required String stopKey,
    required String direction,
    required int leadMinutes,
    required DateTime expiresAt,
    String plate = '',
    String alightEvent = '',
  }) async {
    if (!isArrivalReminderRouteType(routeType) ||
        routeKey.isEmpty ||
        stopKey.isEmpty ||
        (direction != '0' && direction != '1')) {
      throw ArgumentError('invalid canonical arrival identity');
    }
    if (!FirebaseGate.enabled) {
      return ArrivalReminderReceipt(
        reminderId:
            'local:$routeType:$routeKey:$stopKey:'
            '$leadMinutes:$plate:$alightEvent',
      );
    }
    final reminder = await _grpc.createArrivalReminder(
      CreateArrivalReminderRequest(
        installId: await InstallIdentity.getOrCreate(),
        routeType: routeType,
        routeKey: routeKey,
        stopKey: stopKey,
        direction: direction,
        leadMinutes: leadMinutes,
        expiresAtUnix: Int64(expiresAt.millisecondsSinceEpoch ~/ 1000),
        plate: plate,
        alightEvent: alightEvent,
      ),
      options: await FirebaseCallOptions.build(),
    );
    return FirebaseDecoder.instance.decodeReminder(reminder);
  }

  Future<FirebaseAck> cancelArrivalReminder(String reminderId) async {
    if (!FirebaseGate.enabled) {
      return const FirebaseAck(ok: true, message: 'disabled');
    }
    final ack = await _grpc.cancelArrivalReminder(
      CancelArrivalReminderRequest(
        reminderId: reminderId,
        installId: await InstallIdentity.getOrCreate(),
      ),
      options: await FirebaseCallOptions.build(),
    );
    return FirebaseDecoder.instance.decodeAck(ack);
  }

  Future<FirebaseDeviceState> listDeviceState() async {
    if (!FirebaseGate.enabled) return const FirebaseDeviceState();
    final state = await _grpc.listDeviceState(
      DeviceRequest(installId: await InstallIdentity.getOrCreate()),
      options: await FirebaseCallOptions.build(),
    );
    return FirebaseDecoder.instance.decodeDeviceState(state);
  }
}
