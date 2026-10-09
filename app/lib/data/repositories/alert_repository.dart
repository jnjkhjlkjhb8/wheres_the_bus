import 'package:wheres_the_bus/core/grpc/grpc_client.dart';
import 'package:wheres_the_bus/data/decoders/alert_decoder.dart';
import 'package:wheres_the_bus/data/generated/alert.pbgrpc.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';

class AlertRepository {
  AlertRepository({Alert_ServiceClient? client, SettingsRepository? settings})
    : _client = client,
      _settings = settings ?? SettingsRepository.instance;

  static final AlertRepository instance = AlertRepository();

  final Alert_ServiceClient? _client;
  Alert_ServiceClient get _grpc => _client ?? GrpcClient.instance.alert;

  final SettingsRepository _settings;

  /// Alert message keys the user has already read, persisted across restarts.
  Set<String> readAlerts() => _settings.readAlerts();

  Future<void> persistReadAlerts(Set<String> read) =>
      _settings.setReadAlerts(read);

  /// Server-streaming: emits bus service disruptions for [city] until
  /// cancelled.
  Stream<List<AlertViewModel>> busAlert(String city) => _decoded(
    _grpc.busAlert(Alert_Bus_Ask(city: city)),
    AlertSource(AlertSourceKind.busAlert, city),
  );

  /// Server-streaming: emits metro service alerts for [system] until cancelled.
  ///
  /// [system] — metro operator code, e.g. `'TRTC'`.
  Stream<List<AlertViewModel>> metroAlert(String system) => _decoded(
    _grpc.metroAlert(Alert_Metro_Ask(system: system)),
    AlertSource(AlertSourceKind.metro, system),
  );

  /// Server-streaming: emits TRA nationwide service alerts.
  Stream<List<AlertViewModel>> traAlert() => _decoded(
    _grpc.traAlert(Alert_Ask()),
    const AlertSource(AlertSourceKind.tra),
  );

  /// Server-streaming: emits THSR nationwide service alerts.
  Stream<List<AlertViewModel>> thsrAlert() => _decoded(
    _grpc.thsrAlert(Alert_Ask()),
    const AlertSource(AlertSourceKind.thsr),
  );

  Stream<List<AlertViewModel>> _decoded(
    Stream<Alert_Msg> source,
    AlertSource from,
  ) => source.map((msg) => AlertDecoder.instance.decode(msg, source: from));
}
