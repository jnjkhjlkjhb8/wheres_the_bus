import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';

class MapMarkers {
  const MapMarkers._();

  static const int _cacheCap = 256;
  static final LinkedHashMap<String, Object> _cache =
      LinkedHashMap<String, Object>();

  static const int _bubbleCacheCap = 16;
  static final LinkedHashMap<String, Object> _bubbleCache =
      LinkedHashMap<String, Object>();

  static double _dpr = 3;

  static const double _maxTextScale = 1.3;

  static double _textScale = 1;

  static double get _unit => _dpr * _textScale;

  /// Called from the root `MaterialApp.router` builder, which is the one place
  /// that sees every screen and rebuilds when either value changes. Marker
  /// bitmaps are painted off-tree, so this is how they learn what to paint at.
  static void configure({
    required double devicePixelRatio,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    if (devicePixelRatio > 0) _dpr = devicePixelRatio;
    // Derived at 12pt because every size these bitmaps paint sits between 10.5
    // and 13.5 — a non-linear scaler is then sampled where it actually applies,
    // rather than at the meaningless 1pt that `scale(1)` would report.
    _textScale = (textScaler.scale(12) / 12).clamp(1.0, _maxTextScale);
  }

  static Future<BitmapDescriptor> svgAsset(
    String asset, {
    double size = 36,
  }) {
    return _memo('svg:$asset:$size', () async {
      final info = await vg.loadPicture(SvgAssetLoader(asset), null);
      final px = (size * _dpr).round();
      final image = await _record(px, (canvas) {
        final scale = px / info.size.width;
        canvas
          ..scale(scale)
          ..drawPicture(info.picture);
      });
      info.picture.dispose();
      return _toBitmap(image);
    });
  }

  static Future<BitmapDescriptor> busMark({
    required Color body,
    required Color halo,
    Color? ring,
    bool showHeading = true,
    bool shadow = true,
    double size = 28,
  }) {
    final key =
        'busmark:${body.toARGB32()}:${halo.toARGB32()}:${ring?.toARGB32()}:'
        '$showHeading:$shadow:$size';
    return _memo(key, () async {
      // One unit = one logical px at the designed 28pt body, so every constant
      // below reads as its measurement from the design mock.
      final u = size / 28 * _dpr;
      final half = 24 * u;
      final c = Offset(half, half);
      final disc = Path()..addOval(Rect.fromCircle(center: c, radius: 14 * u));

      Paint outline(Color color, double width) => Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * u;

      final image = await _record((half * 2).round(), (canvas) {
        if (shadow) {
          canvas.drawPath(
            disc.shift(Offset(0, 1.5 * u)),
            Paint()
              ..color = const Color(0x24000000)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * u),
          );
        }
        // Widened when a ring is coming, which eats into the halo's band.
        canvas.drawPath(disc, outline(halo, ring == null ? 5 : 7.5));
        if (ring != null) canvas.drawPath(disc, outline(ring, 2.5));
        // Over both strokes, so they read as bands around the mark rather than
        // rings biting into it.
        canvas.drawPath(disc, Paint()..color = body);
        if (showHeading) {
          // Sits a shade forward of centre: dead-centre reads as an ornament,
          // and any further forward crowds the halo.
          canvas.drawPath(
            Path()
              ..moveTo(c.dx - 6.5 * u, c.dy + 2.5 * u)
              ..lineTo(c.dx, c.dy - 4.5 * u)
              ..lineTo(c.dx + 6.5 * u, c.dy + 2.5 * u),
            outline(halo, 3.2)
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round,
          );
        }
      });
      return _toBitmap(image);
    });
  }

  static Future<({BitmapDescriptor icon, Offset anchor})> stationCapsule({
    required String asset,
    required String label,
    required bool selected,
    required bool flip,
    Color plateGround = AppTheme.surfaceCardLight,
    double size = 30,
  }) {
    final key =
        'cap:$asset:$label:$selected:$flip:${plateGround.toARGB32()}:$size';
    return _memo(key, () async {
      final s = size * _unit;
      final radius = Radius.circular(s * 10 / 45);
      // Room for the shadow's blur and offset; trimmed tight, because every
      // transparent pixel here is texture the map uploads per marker.
      final margin = 8.0 * _unit;
      final padH = 10.0 * _unit;

      final fill = selected ? AppTheme.inkLight : AppTheme.surfaceCardLight;
      final ink = selected ? AppTheme.surfaceCardLight : AppTheme.inkLight;
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: ink,
            fontSize: 12 * _unit,
            fontWeight: FontWeight.w600,
            fontFamily: 'IBMPlexSans',
            height: 1.2,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 132 * _unit);

      final labelW = painter.width + padH * 2;
      final bodyW = s + labelW;
      final w = (margin * 2 + bodyW).ceil();
      final h = (margin * 2 + s).ceil();
      final left = margin;
      final plateLeft = margin + (flip ? labelW : 0);

      final info = await vg.loadPicture(SvgAssetLoader(asset), null);
      final image = await _recordSized(w, h, (canvas) {
        final body = RRect.fromRectAndRadius(
          Rect.fromLTWH(left, margin, bodyW, s),
          radius,
        );
        canvas
          ..drawRRect(
            body.shift(Offset(0, 1.5 * _unit)),
            Paint()
              ..color = const Color(0x1F000000)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * _unit),
          )
          ..drawRRect(body, Paint()..color = fill)
          // The plate's own ground, square on the side the label meets.
          ..drawRRect(
            RRect.fromRectAndCorners(
              Rect.fromLTWH(plateLeft, margin, s, s),
              topLeft: flip ? Radius.zero : radius,
              bottomLeft: flip ? Radius.zero : radius,
              topRight: flip ? radius : Radius.zero,
              bottomRight: flip ? radius : Radius.zero,
            ),
            Paint()..color = plateGround,
          )
          ..save()
          ..translate(plateLeft, margin)
          ..scale(s / info.size.width)
          ..drawPicture(info.picture)
          ..restore();
        painter.paint(
          canvas,
          Offset(
            (flip ? left : plateLeft + s) + padH,
            margin + (s - painter.height) / 2,
          ),
        );
      });
      info.picture.dispose();
      return (
        icon: await _toBitmap(image),
        // Pin by the plate's centre, wherever in the bitmap it landed.
        anchor: Offset((plateLeft + s / 2) / w, 0.5),
      );
    });
  }

  static Future<BitmapDescriptor> dot(
    Color color, {
    double size = 18,
    Color? ring,
  }) {
    final key = 'dot:${color.toARGB32()}:$size:${ring?.toARGB32()}';
    return _memo(key, () async {
      final px = (size * _dpr).round();
      final r = px / 2;
      final image = await _record(px, (canvas) {
        final c = Offset(r, r);
        if (ring != null) {
          canvas
            ..drawCircle(c, r, Paint()..color = ring)
            ..drawCircle(c, r * 0.82, Paint()..color = color);
        } else {
          canvas.drawCircle(c, r, Paint()..color = color);
        }
      });
      return _toBitmap(image);
    });
  }

  /// Filled disc with a small concentric inner dot — the heaviest node in the
  /// plan-preview marker language, used for the destination. [fill] is the
  /// outer body, [inner] the centre dot.
  static Future<BitmapDescriptor> targetDot(
    Color fill,
    Color inner, {
    double size = 22,
  }) {
    final key = 'target:${fill.toARGB32()}:${inner.toARGB32()}:$size';
    return _memo(key, () async {
      final px = (size * _dpr).round();
      final r = px / 2;
      final image = await _record(px, (canvas) {
        final c = Offset(r, r);
        canvas
          ..drawCircle(c, r, Paint()..color = fill)
          ..drawCircle(c, r * 0.32, Paint()..color = inner);
      });
      return _toBitmap(image);
    });
  }

  static Future<({BitmapDescriptor icon, Offset anchor})> stopMarker({
    required Color fill,
    required Color content,
    Color? ring,
    double ringWidth = 2,
    double height = 32,
    String? text,
    IconData? glyph,
    bool pill = false,
    String? label,
    Color labelFill = AppTheme.inkLight,
    Color labelInk = AppTheme.surfaceCardLight,
    bool flip = false,
  }) {
    final key =
        'stop:$height:${fill.toARGB32()}:${content.toARGB32()}:'
        '${ring?.toARGB32()}:$ringWidth:$text:${glyph?.codePoint}:$pill:'
        '$label:${labelFill.toARGB32()}:${labelInk.toARGB32()}:$flip';
    return _memo(key, () async {
      final h = height * _unit;
      final radius = Radius.circular(h / 2);
      // Room for the shadow's blur and offset. Trimmed tight — every
      // transparent pixel is texture the map uploads, once per stop on a route
      // that can run 60 stops long.
      final margin = 5.0 * _unit;
      final padH = 11.0 * _unit;

      final contentPainter = TextPainter(
        text: TextSpan(
          text: glyph != null
              ? String.fromCharCode(glyph.codePoint)
              : (text ?? ''),
          style: TextStyle(
            color: content,
            fontSize: switch ((glyph, pill)) {
              (final IconData _, _) => h * 0.5,
              (_, true) => 12 * _unit,
              // Three characters only fit a disc at the smaller step; two or
              // fewer (the common countdown) get the readable one.
              _ => h * ((text?.length ?? 0) > 2 ? 0.30 : 0.42),
            },
            fontWeight: FontWeight.w700,
            fontFamily:
                glyph?.fontFamily ?? (pill ? 'IBMPlexSans' : 'IBMPlexMono'),
            package: glyph?.fontPackage,
            fontFeatures: const [ui.FontFeature.tabularFigures()],
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final labelPainter = label == null
          ? null
          : (TextPainter(
              text: TextSpan(
                text: label,
                style: TextStyle(
                  color: labelInk,
                  fontSize: 12 * _unit,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'IBMPlexSans',
                  height: 1.2,
                ),
              ),
              maxLines: 1,
              ellipsis: '…',
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: 132 * _unit));

      final plateW = pill ? contentPainter.width + padH * 2 : h;
      final labelW = labelPainter == null ? 0.0 : labelPainter.width + padH * 2;
      final bodyW = plateW + labelW;
      final w = (margin * 2 + bodyW).ceil();
      final imageH = (margin * 2 + h).ceil();
      final plateLeft = margin + (flip ? labelW : 0);

      final image = await _recordSized(w, imageH, (canvas) {
        final body = RRect.fromRectAndRadius(
          Rect.fromLTWH(margin, margin, bodyW, h),
          radius,
        );
        // Lifts the plate off arbitrary map tiles. Barely visible against the
        // dark basemap, which is the same trade AppTheme.floatingControl makes.
        canvas.drawRRect(
          body.shift(Offset(0, 1.5 * _unit)),
          Paint()
            ..color = const Color(0x24000000)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * _unit),
        );
        if (labelPainter != null) {
          canvas.drawRRect(body, Paint()..color = labelFill);
        }
        // The plate is drawn whole, over the capsule body, and its end cap is
        // the body's own — so no corner of the body can show through, and none
        // of the squaring [stationCapsule] needs is required here.
        final plate = RRect.fromRectAndRadius(
          Rect.fromLTWH(plateLeft, margin, plateW, h),
          radius,
        );
        canvas.drawRRect(plate, Paint()..color = fill);
        if (ring != null) {
          canvas.drawRRect(
            plate.deflate(ringWidth * _unit / 2),
            Paint()
              ..color = ring
              ..style = PaintingStyle.stroke
              ..strokeWidth = ringWidth * _unit,
          );
        }
        contentPainter.paint(
          canvas,
          Offset(
            plateLeft + (plateW - contentPainter.width) / 2,
            margin + (h - contentPainter.height) / 2,
          ),
        );
        labelPainter?.paint(
          canvas,
          Offset(
            (flip ? margin : plateLeft + plateW) + padH,
            margin + (h - labelPainter.height) / 2,
          ),
        );
      });
      return (
        icon: await _toBitmap(image),
        // Pin by the plate's centre, wherever in the bitmap it landed.
        anchor: Offset((plateLeft + plateW / 2) / w, 0.5),
      );
    });
  }

  static Future<BitmapDescriptor> navArrow(
    Color disc,
    Color ring, {
    double size = 48,
  }) {
    final key = 'navarrow:${disc.toARGB32()}:${ring.toARGB32()}:$size';
    return _memo(key, () async {
      final px = (size * _dpr).round();
      final center = Offset(px / 2, px / 2);
      final rOuter = px * (20 / 48);
      final rInk = px * (17 / 48);
      final image = await _record(px, (canvas) {
        canvas
          ..drawCircle(
            center + Offset(0, px * (2.5 / 48)),
            rOuter,
            Paint()
              ..color = const Color(0x2E000000)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, px * (3 / 48)),
          )
          ..drawCircle(center, rOuter, Paint()..color = ring)
          ..drawCircle(center, rInk, Paint()..color = disc);
        final painter = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(Icons.navigation_rounded.codePoint),
            style: TextStyle(
              color: ring,
              fontSize: px * (26 / 48),
              fontFamily: Icons.navigation_rounded.fontFamily,
              package: Icons.navigation_rounded.fontPackage,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(
          canvas,
          center - Offset(painter.width / 2, painter.height / 2),
        );
      });
      return _toBitmap(image);
    });
  }

  static Future<BitmapDescriptor> busBubble({
    required String plate,
    required Color fill,
    required Color inkSecondary,
    required String statusLabel,
    required Color statusColor,
    required String gpsText,
    String? trackGlyph,
    double clearance = 22,
  }) {
    final key =
        'bubble:$plate:$statusLabel:$gpsText:${fill.toARGB32()}:'
        '${inkSecondary.toARGB32()}:${statusColor.toARGB32()}:'
        '${trackGlyph ?? ''}';
    return _memo(key, store: _bubbleCache, cap: _bubbleCacheCap, () async {
      final statusPainter = TextPainter(
        text: TextSpan(
          text: statusLabel,
          style: TextStyle(
            color: statusColor,
            fontSize: 13.5 * _unit,
            fontWeight: FontWeight.w700,
            fontFamily: 'IBMPlexSans',
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final metaPainter = TextPainter(
        text: TextSpan(
          children: [
            TextSpan(
              text: plate,
              style: TextStyle(letterSpacing: 0.3 * _unit),
            ),
            TextSpan(text: ' · $gpsText'),
            // Pin state (＋ selecting / ✓ tracking) sits to the right of the
            // plate line as a bare ink glyph — no chip, matching the mock.
            if (trackGlyph != null)
              TextSpan(
                text: '  $trackGlyph',
                style: TextStyle(
                  fontSize: 13 * _unit,
                  fontWeight: FontWeight.w800,
                ),
              ),
          ],
          style: TextStyle(
            color: inkSecondary,
            fontSize: 10.5 * _unit,
            fontWeight: FontWeight.w600,
            fontFamily: 'IBMPlexMono',
            fontFeatures: const [ui.FontFeature.tabularFigures()],
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final padH = 11.0 * _unit;
      final padTop = 6.0 * _unit;
      final padBottom = 7.0 * _unit;
      final lineGap = 1.0 * _unit;
      final tailW = 12.0 * _unit;
      final tailH = 6.0 * _unit;
      final margin = 12.0 * _unit;

      final contentW = [
        statusPainter.width,
        metaPainter.width,
      ].reduce((a, b) => a > b ? a : b);
      final bubbleW = contentW + padH * 2;
      final bubbleH =
          padTop +
          statusPainter.height +
          lineGap +
          metaPainter.height +
          padBottom;
      final w = (bubbleW + margin * 2).ceil();
      final h = (margin + bubbleH + tailH + clearance * _dpr).ceil();
      final cx = w / 2;

      final image = await _recordSized(w, h, (canvas) {
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(margin, margin, bubbleW, bubbleH),
          Radius.circular(10 * _unit),
        );
        final body = Path()
          ..addRRect(rect)
          ..moveTo(cx - tailW / 2, margin + bubbleH)
          ..lineTo(cx + tailW / 2, margin + bubbleH)
          ..lineTo(cx, margin + bubbleH + tailH)
          ..close();
        canvas
          ..drawPath(
            body.shift(Offset(0, 2 * _unit)),
            Paint()
              ..color = const Color(0x29000000)
              ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 * _unit),
          )
          ..drawPath(body, Paint()..color = fill);
        statusPainter.paint(
          canvas,
          Offset(cx - statusPainter.width / 2, margin + padTop),
        );
        metaPainter.paint(
          canvas,
          Offset(
            cx - metaPainter.width / 2,
            margin + padTop + statusPainter.height + lineGap,
          ),
        );
      });
      return _toBitmap(image);
    });
  }

  static Future<T> _memo<T extends Object>(
    String key,
    Future<T> Function() build, {
    LinkedHashMap<String, Object>? store,
    int? cap,
  }) async {
    final cache = store ?? _cache;
    final cacheCap = cap ?? _cacheCap;
    final cacheKey = '$key:$_dpr:$_textScale';
    final hit = cache.remove(cacheKey);
    if (hit != null) {
      // Re-insert to mark most-recently-used (LinkedHashMap preserves
      // insertion order). BitmapDescriptor needs no explicit dispose.
      cache[cacheKey] = hit;
      return hit as T;
    }
    final made = await build();
    if (cache.length >= cacheCap) {
      cache.remove(cache.keys.first);
    }
    cache[cacheKey] = made;
    return made;
  }

  static Future<ui.Image> _record(int px, void Function(Canvas) draw) =>
      _recordSized(px, px, draw);

  static Future<ui.Image> _recordSized(
    int w,
    int h,
    void Function(Canvas) draw,
  ) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    draw(canvas);
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(w, h);
    } finally {
      picture.dispose();
    }
  }

  static Future<BitmapDescriptor> _toBitmap(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return BitmapDescriptor.bytes(
      data!.buffer.asUint8List(),
      imagePixelRatio: _dpr,
    );
  }
}
