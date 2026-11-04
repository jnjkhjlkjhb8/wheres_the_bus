import 'package:geolocator/geolocator.dart';
import 'package:wheres_the_bus/data/models/city_names.dart';

/// Farther than this from every centroid the rider is not in a covered city
/// (or abroad), and claiming one would reorder results for nothing.
const _maxCentroidMeters = 40000.0;

/// Approximate city centres, keyed by the TDX codes `search_vector.city`
/// uses. A nearest-centre guess is enough to answer "which city's routes do I
/// mean", and it needs no network call or boundary data; it is wrong only
/// within a few km of a shared border.
const _cityCentroids = <String, (double, double)>{
  'Keelung': (25.1276, 121.7392),
  'Taipei': (25.0478, 121.5515),
  'NewTaipei': (25.0120, 121.4650),
  'Taoyuan': (24.9936, 121.3010),
  'Hsinchu': (24.8138, 120.9675),
  'HsinchuCounty': (24.8387, 121.0178),
  'MiaoliCounty': (24.5602, 120.8214),
  'Taichung': (24.1477, 120.6736),
  'ChanghuaCounty': (24.0518, 120.5161),
  'NantouCounty': (23.9157, 120.6869),
  'YunlinCounty': (23.7092, 120.4313),
  'Chiayi': (23.4801, 120.4491),
  'ChiayiCounty': (23.4518, 120.2555),
  'Tainan': (22.9999, 120.2270),
  'Kaohsiung': (22.6273, 120.3014),
  'PingtungCounty': (22.6762, 120.4940),
  'YilanCounty': (24.7021, 121.7378),
  'HualienCounty': (23.9772, 121.6044),
  'TaitungCounty': (22.7583, 121.1444),
};

/// Whether a search result's [resultCity] is the rider's [riderCode]. The
/// router has been seen to send either the TDX code or the Chinese name in
/// `city`, so both spellings count.
bool sameCity(String? resultCity, String? riderCode) =>
    resultCity != null &&
    riderCode != null &&
    (resultCity == riderCode || resultCity == cityName(riderCode));

/// TDX code of the city nearest [fix], or null without a fix or when no
/// city is within range.
String? riderCityFor(Position? fix) {
  if (fix == null) return null;
  String? best;
  var bestMeters = _maxCentroidMeters;
  for (final entry in _cityCentroids.entries) {
    final meters = Geolocator.distanceBetween(
      fix.latitude,
      fix.longitude,
      entry.value.$1,
      entry.value.$2,
    );
    if (meters < bestMeters) {
      best = entry.key;
      bestMeters = meters;
    }
  }
  return best;
}
