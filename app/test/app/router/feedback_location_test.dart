import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';

void main() {
  test('the report location carries where it came from and what about', () {
    expect(AppRoutes.feedbackLocation(), '/feedback');
    expect(AppRoutes.feedbackLocation(from: '', about: ''), '/feedback');

    final both = Uri.parse(
      AppRoutes.feedbackLocation(from: '/bus/route/X', about: '307 · 往 板橋'),
    );
    expect(both.path, '/feedback');
    expect(both.queryParameters, {
      'from': '/bus/route/X',
      'about': '307 · 往 板橋',
    });

    expect(
      Uri.parse(AppRoutes.feedbackLocation(about: '臺北車站')).queryParameters,
      {'about': '臺北車站'},
    );
    expect(
      Uri.parse(AppRoutes.feedbackLocation(from: '/settings')).queryParameters,
      {'from': '/settings'},
    );
  });
}
