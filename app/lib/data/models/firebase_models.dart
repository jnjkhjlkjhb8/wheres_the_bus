import 'package:equatable/equatable.dart';

/// Server acknowledgement for a firebase-service write.
class FirebaseAck extends Equatable {
  const FirebaseAck({required this.ok, this.message = ''});

  final bool ok;
  final String message;

  @override
  List<Object?> get props => [ok, message];
}

/// Device registration echoed by the server: identity plus notification
/// preferences, flattened from the proto's identity/prefs sub-messages.
class FirebaseDeviceState extends Equatable {
  const FirebaseDeviceState({
    this.installId = '',
    this.fcmToken = '',
    this.platform = '',
    this.appVersion = '',
    this.pushEnabled = false,
  });

  final String installId;
  final String fcmToken;
  final String platform;
  final String appVersion;
  final bool pushEnabled;

  @override
  List<Object?> get props => [
    installId,
    fcmToken,
    platform,
    appVersion,
    pushEnabled,
  ];
}

/// Receipt for a created arrival reminder; [reminderId] is the handle used
/// to cancel it later.
class ArrivalReminderReceipt extends Equatable {
  const ArrivalReminderReceipt({required this.reminderId});

  final String reminderId;

  @override
  List<Object?> get props => [reminderId];
}
