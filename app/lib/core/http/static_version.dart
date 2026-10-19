import 'package:wheres_the_bus/core/http/http_client.dart';

Future<String?> fetchStaticVersion() async {
  try {
    final response = await HttpClient.instance.dio.get<Map<String, dynamic>>(
      '/api/static-version',
    );
    final version = response.data?['version'];
    return version is String && version.isNotEmpty ? version : null;
  } on Object {
    return null;
  }
}
