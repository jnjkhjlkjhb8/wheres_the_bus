import 'package:url_launcher/url_launcher.dart';
import 'package:wheres_the_bus/core/http/http_client.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';

/// Passenger categories THSR prices separately. TRA's deeplink takes no ticket
/// parameters at all, so this drives the THSR booking sheet only.
enum TicketCategory { adult, child, disabled, senior, student }

extension TicketCategoryLabel on TicketCategory {
  String labelOf(AppI18n i18n) => switch (this) {
    TicketCategory.adult => i18n.ticketAdult,
    TicketCategory.child => i18n.ticketChild,
    TicketCategory.disabled => i18n.ticketDisabled,
    TicketCategory.senior => i18n.ticketSenior,
    TicketCategory.student => i18n.ticketStudent,
  };

  /// Query-parameter stem the router expects (`<name>_ticket`).
  String get param => name;
}

/// TDX's documented per-category ceiling for THSR.
const int kMaxTicketsPerCategory = 10;

/// TRA's per-order ticket ceiling. TRA takes one quantity for the whole order
/// rather than THSR's count-per-category.
const int kMaxTraTickets = 9;

/// TRA booking classes. TDX calls this `ticket_type`, but unlike THSR's
/// `ticket_type` (trip type) it selects the carriage/booking class.
enum TraBookingClass {
  standard(1),
  tengyun(2),
  bikeOnboard(3);

  const TraBookingClass(this.code);
  final int code;

  String labelOf(AppI18n i18n) => switch (this) {
    TraBookingClass.standard => i18n.railBookingClassStandard,
    TraBookingClass.tengyun => i18n.railBookingClassTengyun,
    TraBookingClass.bikeOnboard => i18n.railBookingClassBike,
  };
}

/// A booking hand-off in the app's own terms. The three upstream variants take
/// different parameters; that mapping lives in the router, so this stays the
/// shape of what the user actually chose.
class RailBookingRequest {
  const RailBookingRequest({
    required this.isThsr,
    required this.origin,
    required this.destination,
    required this.date,
    required this.time,
    required this.trainNumber,
    this.business = false,
    this.tickets = const {TicketCategory.adult: 1},
    this.traClass = TraBookingClass.standard,
    this.traCount = 1,
  });

  final bool isThsr;
  final String origin;
  final String destination;

  /// `yyyy-MM-dd`.
  final String date;

  /// `HH:mm` departure time. Required by THSR, unused by TRA.
  final String time;
  final String trainNumber;

  /// THSR business cabin (J) rather than standard (Y).
  final bool business;

  /// Per-category ticket counts. THSR only; TRA ignores them.
  final Map<TicketCategory, int> tickets;

  /// TRA booking class. THSR ignores it.
  final TraBookingClass traClass;

  /// TRA ticket quantity for the whole order (1–[kMaxTraTickets]).
  final int traCount;

  /// Tickets in this order, however the operator counts them.
  int get ticketTotal =>
      isThsr ? tickets.values.fold(0, (sum, n) => sum + n) : traCount;

  RailBookingRequest copyWith({
    bool? business,
    Map<TicketCategory, int>? tickets,
    TraBookingClass? traClass,
    int? traCount,
  }) => RailBookingRequest(
    isThsr: isThsr,
    origin: origin,
    destination: destination,
    date: date,
    time: time,
    trainNumber: trainNumber,
    business: business ?? this.business,
    tickets: tickets ?? this.tickets,
    traClass: traClass ?? this.traClass,
    traCount: traCount ?? this.traCount,
  );
}

/// Outcome of a hand-off attempt, so the caller can tell the user what actually
/// happened instead of silently opening an unfilled page.
enum BookingLaunchResult {
  /// A pre-filled booking page (or the operator app) was opened.
  prefilled,

  /// The exchange failed; the plain booking site was opened with nothing filled
  /// in.
  fallback,

  /// Nothing could be opened at all.
  failed,
}

Future<bool> isOperatorAppInstalled({required bool isThsr}) async {
  try {
    return await canLaunchUrl(Uri.parse(isThsr ? 'thsrc://' : 'tra-tip://'));
  } on Object catch (_) {
    return false;
  }
}

Future<String?> fetchRailBookingUrl(
  RailBookingRequest request, {
  required bool useApp,
}) async {
  try {
    final res = await HttpClient.instance.dio.get<Map<String, dynamic>>(
      '/api/booking/deeplink',
      queryParameters: <String, String>{
        'agency': request.isThsr ? 'hsr' : 'tra',
        'kind': useApp ? 'direct' : 'web',
        'start_station': request.origin,
        'end_station': request.destination,
        'train_date': request.date,
        'train_number': request.trainNumber,
        // The two operators take unrelated ticket parameters — THSR counts per
        // passenger category, TRA takes one quantity plus a booking class — so
        // each agency sends only its own. The router maps them per variant.
        if (request.isThsr) ...{
          'train_time': request.time,
          'carriage_type': request.business ? 'J' : 'Y',
          for (final entry in request.tickets.entries)
            '${entry.key.param}_ticket': '${entry.value}',
        } else ...{
          'ticket_type': '${request.traClass.code}',
          'ticket_count': '${request.traCount}',
        },
      },
    );
    final url = res.data?['url'];
    return url is String && url.isNotEmpty ? url : null;
  } on Object catch (_) {
    // Router unavailable (e.g. non-prod has no TDX credentials → 503) or
    // network error: the caller falls back to the plain booking site.
    return null;
  }
}

/// Opens [url] when the exchange produced one, else the operator's plain
/// booking site. Returns what the user actually got.
Future<BookingLaunchResult> openRailBooking({
  required String? url,
  required bool isThsr,
}) async {
  final target = url ?? _fallbackBookingSite(isThsr);
  try {
    final opened = await launchUrl(
      Uri.parse(target),
      mode: LaunchMode.externalApplication,
    );
    if (!opened) return BookingLaunchResult.failed;
  } on Object catch (_) {
    return BookingLaunchResult.failed;
  }
  return url == null
      ? BookingLaunchResult.fallback
      : BookingLaunchResult.prefilled;
}

String _fallbackBookingSite(bool isThsr) => isThsr
    ? 'https://irs.thsrc.com.tw/IMINT/'
    : 'https://www.railway.gov.tw/tra-tip-web/tip/tip001/tip123/query';
