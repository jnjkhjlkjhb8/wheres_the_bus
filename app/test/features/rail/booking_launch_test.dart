import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/http/http_client.dart';
import 'package:wheres_the_bus/features/rail/booking_launch.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_booking_sheet.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_sliding_segment.dart';

RailBookingRequest booking({bool thsr = true}) => RailBookingRequest(
  isThsr: thsr,
  origin: '1000',
  destination: '1020',
  date: '2030-01-02',
  time: '08:30',
  trainNumber: '123',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late InterceptorsWrapper router;
  final requests = <RequestOptions>[];
  final launches = <MethodCall>[];
  Object? body;
  var offline = false;
  var installed = true;
  var open = true;
  var pluginError = false;
  Completer<void>? gate;
  setUp(() {
    requests.clear();
    launches.clear();
    body = {'url': 'https://booking.example.test/prefilled'};
    offline = false;
    installed = true;
    open = true;
    pluginError = false;
    gate = null;
    router = InterceptorsWrapper(
      onRequest: (request, handler) async {
        requests.add(request);
        if (gate != null) await gate!.future;
        if (offline) {
          handler.reject(DioException(requestOptions: request));
        } else {
          handler.resolve(Response(requestOptions: request, data: body));
        }
      },
    );
    HttpClient.instance.dio.interceptors.add(router);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          (call) async {
            if (pluginError) throw PlatformException(code: 'unavailable');
            launches.add(call);
            return call.method == 'canLaunch' ? installed : open;
          },
        );
  });
  tearDown(() {
    HttpClient.instance.dio.interceptors.remove(router);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        );
  });

  test('THSR exchanges only its category and cabin parameters', () async {
    final request = booking().copyWith(
      business: true,
      tickets: {TicketCategory.adult: 2, TicketCategory.child: 1},
    );
    expect(
      await fetchRailBookingUrl(request, useApp: false),
      'https://booking.example.test/prefilled',
    );
    expect(requests.single.path, '/api/booking/deeplink');
    expect(requests.single.queryParameters, {
      'agency': 'hsr',
      'kind': 'web',
      'start_station': '1000',
      'end_station': '1020',
      'train_date': '2030-01-02',
      'train_number': '123',
      'train_time': '08:30',
      'carriage_type': 'J',
      'adult_ticket': '2',
      'child_ticket': '1',
    });
    expect(request.ticketTotal, 3);
    await fetchRailBookingUrl(booking(), useApp: true);
    expect(requests.last.queryParameters['carriage_type'], 'Y');
    expect(requests.last.queryParameters['kind'], 'direct');
  });
  test('TRA exchanges its class and total without THSR categories', () async {
    final request = booking(
      thsr: false,
    ).copyWith(traClass: TraBookingClass.bikeOnboard, traCount: 4);
    await fetchRailBookingUrl(request, useApp: true);
    expect(requests.single.queryParameters, {
      'agency': 'tra',
      'kind': 'direct',
      'start_station': '1000',
      'end_station': '1020',
      'train_date': '2030-01-02',
      'train_number': '123',
      'ticket_type': '3',
      'ticket_count': '4',
    });
    expect(request.ticketTotal, 4);
  });
  test('absent, empty, invalid and offline exchanges return no URL', () async {
    for (final response in [
      null,
      <String, Object?>{},
      {'url': ''},
      {'url': 5},
    ]) {
      body = response;
      expect(await fetchRailBookingUrl(booking(), useApp: false), isNull);
    }
    offline = true;
    expect(await fetchRailBookingUrl(booking(), useApp: false), isNull);
  });
  test(
    'installed app probing and launch outcomes retain operator URLs',
    () async {
      expect(await isOperatorAppInstalled(isThsr: true), isTrue);
      expect((launches.last.arguments as Map)['url'], 'thsrc://');
      installed = false;
      expect(await isOperatorAppInstalled(isThsr: false), isFalse);
      expect((launches.last.arguments as Map)['url'], 'tra-tip://');
      expect(
        await openRailBooking(url: 'tra-tip://123', isThsr: false),
        BookingLaunchResult.prefilled,
      );
      expect(
        await openRailBooking(url: null, isThsr: true),
        BookingLaunchResult.fallback,
      );
      expect(
        (launches.last.arguments as Map)['url'],
        'https://irs.thsrc.com.tw/IMINT/',
      );
      await openRailBooking(url: null, isThsr: false);
      expect(
        (launches.last.arguments as Map)['url'],
        contains('railway.gov.tw'),
      );
      open = false;
      expect(
        await openRailBooking(url: 'tra-tip://123', isThsr: false),
        BookingLaunchResult.failed,
      );
      pluginError = true;
      expect(await isOperatorAppInstalled(isThsr: true), isFalse);
      expect(
        await openRailBooking(url: null, isThsr: true),
        BookingLaunchResult.failed,
      );
    },
  );

  Future<void> show(WidgetTester tester, RailBookingRequest request) async {
    tester.view.physicalSize = const Size(430, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('zh'),
        localizationsDelegates: AppI18n.localizationsDelegates,
        supportedLocales: AppI18n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showRailBookingSheet(
                context,
                request,
                trainType: '新自強',
                hasBikeService: true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void press(WidgetTester tester, String label) {
    final finder = find.byWidgetPredicate(
      (widget) => widget is Pressable && widget.semanticLabel == label,
    );
    tester.widget<Pressable>(finder).onTap!();
  }

  testWidgets('THSR changes discard cached URLs and open the fresh order', (
    tester,
  ) async {
    await show(tester, booking());
    expect(requests, hasLength(1));
    final segment = tester.widget<AppSlidingSegment<bool>>(
      find.byType(AppSlidingSegment<bool>),
    );
    segment.onChanged(true);
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['carriage_type'], 'J');
    final increase = tester
        .widgetList<Pressable>(find.byType(Pressable))
        .where((widget) => widget.semanticLabel?.contains('增加') ?? false)
        .first;
    increase.onTap!();
    await tester.pumpAndSettle();
    final count = requests.length;
    press(tester, '前往訂票');
    await tester.pumpAndSettle();
    expect(requests, hasLength(count));
    expect(find.byType(AppSlidingSegment<bool>), findsNothing);
  });
  testWidgets('TRA failed exchange offers explicit unfilled fallback', (
    tester,
  ) async {
    offline = true;
    installed = false;
    await show(tester, booking(thsr: false));
    press(tester, '前往訂票');
    await tester.pumpAndSettle();
    final fallback = tester
        .widgetList<Pressable>(find.byType(Pressable))
        .where((widget) => widget.semanticLabel?.contains('仍') ?? false)
        .first;
    fallback.onTap!();
    await tester.pumpAndSettle();
    expect((launches.last.arguments as Map)['url'], contains('railway.gov.tw'));
  });

  Pressable pressable(WidgetTester tester, String label) =>
      tester.widget<Pressable>(
        find.byWidgetPredicate(
          (w) => w is Pressable && w.semanticLabel == label,
        ),
      );

  testWidgets('the operator app shortcut shows only when it is installed', (
    tester,
  ) async {
    final i18n = lookupAppI18n(const Locale('zh'));
    await show(tester, booking());
    expect(find.text(i18n.railOpenOperatorApp('高鐵')), findsOneWidget);
    expect(find.text(i18n.railBookingAppNoCount), findsOneWidget);

    installed = false;
    await show(tester, booking(thsr: false));
    expect(find.text(i18n.railOpenOperatorApp('台鐵')), findsNothing);
  });

  testWidgets('each operator lists its own notes', (tester) async {
    final i18n = lookupAppI18n(const Locale('zh'));
    await show(tester, booking());
    expect(find.text(i18n.railBookingIdNote), findsOneWidget);
    expect(find.text(i18n.railBookingThsrFareNote), findsOneWidget);
    expect(find.text(i18n.railBookingTraFareNote), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await show(tester, booking(thsr: false));
    expect(find.text(i18n.railBookingTraCategoryNote), findsOneWidget);
    expect(find.text(i18n.railBookingTraFareNote), findsOneWidget);
    expect(find.text(i18n.railBookingIdNote), findsNothing);
  });

  testWidgets('the order needs a ticket, and each step moves by one', (
    tester,
  ) async {
    final i18n = lookupAppI18n(const Locale('zh'));
    await show(tester, booking());
    final adult = i18n.stepperDecrease(TicketCategory.adult.labelOf(i18n));
    final more = i18n.stepperIncrease(TicketCategory.adult.labelOf(i18n));

    expect(pressable(tester, i18n.railBookingGoSemantics).onTap, isNotNull);
    expect(pressable(tester, adult).enabled, isTrue);
    pressable(tester, adult).onTap!();
    await tester.pumpAndSettle();
    expect(pressable(tester, i18n.railBookingGoSemantics).onTap, isNull);
    expect(pressable(tester, i18n.railBookingGoSemantics).enabled, isFalse);
    expect(pressable(tester, adult).onTap, isNull);
    expect(pressable(tester, adult).enabled, isFalse);

    pressable(tester, more).onTap!();
    await tester.pumpAndSettle();
    pressable(tester, more).onTap!();
    await tester.pumpAndSettle();
    expect(find.text(i18n.railTicketTotal(2)), findsOneWidget);
    expect(pressable(tester, i18n.railBookingGoSemantics).enabled, isTrue);
  });

  testWidgets('a stepper value recedes at zero and speaks at one', (
    tester,
  ) async {
    final i18n = lookupAppI18n(const Locale('zh'));
    await show(tester, booking());
    final cs = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;

    final zero = tester.widget<Text>(find.text('0').first).style!;
    expect(zero.fontSize, 15);
    expect(zero.fontWeight, FontWeight.w400);
    expect(zero.color, cs.outline);
    final one = tester.widget<Text>(find.text('1')).style!;
    expect(one.fontWeight, FontWeight.w600);
    expect(one.color, cs.onSurface);
    expect(i18n, isNotNull);
  });

  testWidgets('booking holds the button until the exchange answers', (
    tester,
  ) async {
    final i18n = lookupAppI18n(const Locale('zh'));
    gate = Completer<void>();
    await show(tester, booking(thsr: false));
    expect(requests, hasLength(1));

    press(tester, i18n.railBookingGoSemantics);
    await tester.pump();
    expect(find.text(i18n.railBookingPreparing), findsOneWidget);
    expect(pressable(tester, i18n.railBookingGoSemantics).onTap, isNull);
    final spinner = tester.widget<SizedBox>(
      find
          .ancestor(
            of: find.byType(CircularProgressIndicator),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect((spinner.width, spinner.height), (15, 15));

    gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text(i18n.railBookingPreparing), findsNothing);
  });

  testWidgets('a launch that cannot open shows the explicit notice', (
    tester,
  ) async {
    final i18n = lookupAppI18n(const Locale('zh'));
    await show(tester, booking(thsr: false));
    open = false;

    press(tester, i18n.railBookingGoSemantics);
    await tester.pumpAndSettle();

    expect(find.text(i18n.railBookingNoTrainNote), findsOneWidget);
    expect(find.text(i18n.railBookingOpenAnyway), findsOneWidget);
    final cs = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    final note = tester.widget<Text>(find.text(i18n.railBookingNoTrainNote));
    expect(note.style!.height, 1.5);
    expect(note.style!.color, cs.onErrorContainer);
  });

  testWidgets('the footer names the order and colours its action', (
    tester,
  ) async {
    final i18n = lookupAppI18n(const Locale('zh'));
    await show(tester, booking());
    final cs = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;

    final route = tester.widget<Text>(find.text('1000 → 1020')).style!;
    expect(route.fontSize, 15);
    expect(route.fontWeight, FontWeight.w700);
    final label = tester.widget<Text>(find.text(i18n.railBookingGoSemantics));
    expect(label.style!.color, cs.onPrimary);
    final fill = tester.widget<Container>(
      find
          .ancestor(
            of: find.text(i18n.railBookingGoSemantics),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((fill.decoration! as BoxDecoration).color, cs.primary);
  });
}
