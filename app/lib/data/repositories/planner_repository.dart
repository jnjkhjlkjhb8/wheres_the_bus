import 'package:wheres_the_bus/core/http/http_client.dart';

class PlannerCapabilities {
  const PlannerCapabilities(this._names);

  const PlannerCapabilities.shared()
    : _names = const {
        'transitModes',
        'itineraryCount',
        'transferWindow',
        'firstLastMile',
        'pricePreference',
      };

  final Set<String> _names;

  bool has(String capability) => _names.contains(capability);

  static const String maxTransfers = 'maxTransfers';
  static const String avoidReservation = 'avoidReservation';
  static const String carryBike = 'carryBike';
  static const String earlierLater = 'earlierLater';
  static const String legAlternatives = 'legAlternatives';
}

class PlannerRepository {
  /// [fetchBody] is the one seam: it returns the decoded response body, or
  /// throws. Injected rather than mocked at the HTTP layer so the cache and
  /// the degrade-to-shared behaviour can be tested without a fake transport.
  PlannerRepository({
    Future<Map<String, dynamic>?> Function()? fetchBody,
    DateTime Function()? now,
  }) : _fetchBody = fetchBody ?? _get,
       _now = now ?? DateTime.now;

  static final PlannerRepository instance = PlannerRepository();

  final Future<Map<String, dynamic>?> Function() _fetchBody;
  final DateTime Function() _now;

  static Future<Map<String, dynamic>?> _get() async {
    final response = await HttpClient.instance.dio.get<Map<String, dynamic>>(
      '/api/planner',
    );
    return response.data;
  }

  static const Duration _freshFor = Duration(seconds: 20);

  ({PlannerCapabilities value, DateTime at})? _cache;

  Future<PlannerCapabilities> capabilities() async {
    final cache = _cache;
    if (cache != null && _now().difference(cache.at) < _freshFor) {
      return cache.value;
    }
    final fetched = await _fetch();
    _cache = (value: fetched, at: _now());
    return fetched;
  }

  Future<PlannerCapabilities> _fetch() async {
    try {
      final names = (await _fetchBody())?['capabilities'];
      if (names is! List) return const PlannerCapabilities.shared();
      return PlannerCapabilities({
        for (final name in names)
          if (name is String) name,
      });
    } on Object {
      return const PlannerCapabilities.shared();
    }
  }
}
