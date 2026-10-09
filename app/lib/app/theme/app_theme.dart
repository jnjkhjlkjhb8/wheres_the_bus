import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:wheres_the_bus/app/theme/app_shadows.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/predictive_back.dart';

class _ReducedMotionCupertinoPageTransitionsBuilder
    extends PageTransitionsBuilder {
  const _ReducedMotionCupertinoPageTransitionsBuilder();

  static const _cupertino = CupertinoPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    }
    return _cupertino.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

class AppTheme {
  AppTheme._();

  static const Color train3000 = Color(0xFF75147C);
  static const Color trainSelfstrong = Color(0xFFF08D36);
  static const Color trainRangecar = Color(0xFF0108B5);
  static const Color trainRangefast = Color(0xFF99C242);
  static const Color trainTaroko = Color(0xFFEC5E2A);
  static const Color trainOrangelight = Color(0xFFF8D448);
  static const Color trainThsr = Color(0xFFDB5325);
  static const Color mrtBL = Color(0xFF0070BD);
  static const Color mrtR = Color(0xFFE3002C);
  static const Color mrtG = Color(0xFF008659);
  static const Color mrtO = Color(0xFFF2A83B);
  static const Color mrtBR = Color(0xFFC48C31);
  static const Color mrtY = Color(0xFFFFDB00);
  static const Color mrtAM = Color(0xFF8246AF);
  static const Color mrtTG = Color(0xFF9BC346);
  static const Color mrtKG = Color(0xFF90BE50);
  static const Color mrtKR = Color(0xFFE3002C);
  static const Color mrtKO = Color(0xFFE6A739);
  static const Color ferryBlue = Color(0xFF0288D1);

  static const Color markerBus = Color(0xFFC03634);
  static const Color markerBike = Color(0xFFDFE24D);
  static const Color markerRail = Color(0xFF285FF4);

  static const Color statusArriving = positive300;
  static const Color statusArrivingText = positive500;
  static const Color statusApproach = warning300;
  static const Color etaArriving = critical500;
  static const Color etaApproaching = warning500;
  static const Color trainDelay = critical400;
  static const Color warningBg = warning50;
  static const Color warningBorder = warning500;

  // Warning surface, split by role. `warningBorder` used to serve as text,
  // icon, and border at once; as text on `warningBg` it only reaches 4.78:1.
  // `warningInk` carries the reading (8.32:1); the border hue stays the accent.
  static const Color warningInkLight = warning600;
  static const Color warningBgDark = warning700;
  static const Color warningInkDark = warning100;

  // Off-ramp by decision, not by drift: this sits 1.6 L* from `warning300`,
  // close enough that the two are hard to tell apart, and was kept distinct
  // anyway. Anything new should take a ramp step instead.
  static const Color warningAccentDark = Color(0xFFE8912B);

  static const Color criticalBg = critical50;
  static const Color criticalInkLight = critical600;
  static const Color criticalAccent = critical500;
  static const Color criticalBgDark = critical700;
  static const Color criticalInkDark = critical100;
  static const Color criticalAccentDark = critical300;

  static const double radiusCard = 12;
  static const double radiusModal = 12;
  static const double radiusBottom = 8;
  static const double radiusStadium = 999;
  static const double radiusSearchBar = 28;
  static const double radiusChip = 4;
  static const double radiusButton = 8;

  /// Corner of a single dock slot in the availability gauge's rack. Below the
  /// chip radius on purpose: a slot is ~6px wide at a full station, where 4px
  /// rounds it into a pill and the rack stops reading as square dock bays.
  static const double radiusSlot = 2;
  static const double radiusBottomSheet = 28;

  static const double space2 = 2;
  static const double space4 = 4;
  static const double space6 = 6;
  static const double space8 = 8;
  static const double space10 = 10;
  static const double space12 = 12;
  static const double space14 = 14;
  static const double space16 = 16;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space32 = 32;
  static const double space48 = 48;

  // Neutral ramp — light. 0 is the page's brightest surface, 900 is ink.
  static const Color ink0Light = Color(0xFFFFFFFF);
  static const Color ink50Light = Color(0xFFF7F7F7);
  static const Color ink100Light = Color(0xFFEFEFEF);
  static const Color ink200Light = Color(0xFFE8E8E8);
  static const Color ink300Light = Color(0xFFE0E0E0);
  static const Color ink400Light = Color(0xFFBFBFBF);
  static const Color ink500Light = Color(0xFFA6A6A6);
  static const Color ink600Light = Color(0xFF868686);
  static const Color ink700Light = Color(0xFF636363);
  static const Color ink800Light = Color(0xFF444444);
  static const Color ink900Light = Color(0xFF111111);

  // Neutral ramp — dark.
  static const Color ink0Dark = Color(0xFF111111);
  static const Color ink50Dark = Color(0xFF1C1C1C);
  static const Color ink100Dark = Color(0xFF282828);
  static const Color ink200Dark = Color(0xFF333333);
  static const Color ink300Dark = Color(0xFF484848);
  static const Color ink400Dark = Color(0xFF5D5D5D);
  static const Color ink500Dark = Color(0xFF717171);
  static const Color ink600Dark = Color(0xFF8C8C8C);
  static const Color ink700Dark = Color(0xFF9E9E9E);
  static const Color ink800Dark = Color(0xFFC9C9C9);
  static const Color ink900Dark = Color(0xFFF5F5F5);

  // Intent ramps. These were already ladders — every value below except the
  // nine marked new was in the palette under an ad-hoc name that hid the
  // structure. Roles are picked from the ramp, never invented alongside it.
  static const Color critical50 = Color(0xFFFDE7E4);
  static const Color critical100 = Color(0xFFFFD9D3);
  static const Color critical200 = Color(0xFFFF7D73); // new
  static const Color critical300 = Color(0xFFF0705E);
  static const Color critical400 = Color(0xFFD92D20);
  static const Color critical500 = Color(0xFFB42318);
  static const Color critical600 = Color(0xFF7A1C13);
  static const Color critical700 = Color(0xFF3B1512);

  static const Color warning50 = Color(0xFFFEF0C7);
  static const Color warning100 = Color(0xFFFBDFA6);
  static const Color warning200 = Color(0xFFFFA673); // new
  static const Color warning300 = Color(0xFFF79009);
  static const Color warning400 = Color(0xFFCA6932); // new
  static const Color warning500 = Color(0xFFB54708);
  static const Color warning600 = Color(0xFF7A2E0E);
  static const Color warning700 = Color(0xFF33230A);

  // Positive had only two values, so a "service restored" notice had no
  // surface to sit on. The ramp is filled to the same eight steps as the
  // other two intents rather than left as a special case.
  static const Color positive50 = Color(0xFFCEF5E1); // new
  static const Color positive100 = Color(0xFFA8F0CA); // new
  static const Color positive200 = Color(0xFF61D798); // new
  static const Color positive300 = Color(0xFF12B76A);
  static const Color positive400 = Color(0xFF25965B); // new
  static const Color positive500 = Color(0xFF0E7C42);
  static const Color positive600 = Color(0xFF0C4F2C); // new
  static const Color positive700 = Color(0xFF062A17); // new

  // Pure Achromatic color tokens (Light Mode)
  static const Color inkLight = ink900Light;
  static const Color inkSecondaryLight = ink700Light;
  static const Color inkDisabledLight = ink400Light;
  static const Color borderLight = ink300Light;
  static const Color surfaceLight = ink50Light;
  static const Color surfaceCardLight = ink0Light;
  static const Color surfacePressLight = ink100Light;
  static const Color surfaceHighlightLight = ink200Light;

  static const Color inkTertiaryLight = ink600Light;
  static const Color inkTertiaryDark = ink600Dark;

  /// Disabled *content*, split from the disabled border it used to share a
  /// value with. A border wants to stay quiet; a label has to stay readable.
  static const Color contentDisabledLight = ink500Light;
  static const Color contentDisabledDark = ink500Dark;

  // Pure Achromatic color tokens (Dark Mode)
  static const Color inkDark = ink900Dark;
  static const Color inkSecondaryDark = ink700Dark;
  static const Color inkDisabledDark = ink300Dark;
  static const Color borderDark = ink300Dark;
  // Dark mode has no usable drop shadow, so each elevation level must be a
  // legible lightness step on its own.
  static const Color surfaceDark = ink0Dark;
  static const Color surfaceCardDark = ink50Dark;
  static const Color surfacePressDark = ink100Dark;
  static const Color surfaceHighlightDark = ink200Dark;

  static Color surfaceHighlight(Brightness brightness) =>
      brightness == Brightness.light
      ? surfaceHighlightLight
      : surfaceHighlightDark;

  static Color inkTertiary(Brightness brightness) =>
      brightness == Brightness.light ? inkTertiaryLight : inkTertiaryDark;

  /// Disabled *content*, as opposed to the disabled boundary `cs.outline`
  /// paints. Kept separate because a label and a hairline want opposite things
  /// from the same "inactive" idea.
  static Color contentDisabled(Brightness brightness) =>
      brightness == Brightness.light
      ? contentDisabledLight
      : contentDisabledDark;

  // Custom static schemes ensuring pure neutral surfaces and maximum contrast
  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: inkLight,
    onPrimary: Colors.white,
    primaryContainer: surfacePressLight,
    onPrimaryContainer: inkLight,
    secondary: inkSecondaryLight,
    onSecondary: Colors.white,
    error: Color(0xFFBA1A1A),
    onError: Colors.white,
    errorContainer: Color(0xFFFFDAD6),
    onErrorContainer: Color(0xFFBA1A1A),
    surface: surfaceLight,
    onSurface: inkLight,
    surfaceContainerLow: surfaceCardLight,
    surfaceContainerHigh: surfaceCardLight,
    surfaceContainerHighest: surfacePressLight,
    onSurfaceVariant: inkSecondaryLight,
    outline: contentDisabledLight,
    outlineVariant: borderLight,
  );

  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: inkDark,
    onPrimary: inkLight,
    primaryContainer: surfacePressDark,
    onPrimaryContainer: inkDark,
    secondary: inkSecondaryDark,
    onSecondary: inkLight,
    error: critical300,
    onError: ink0Dark,
    errorContainer: critical700,
    onErrorContainer: critical100,
    surface: surfaceDark,
    onSurface: inkDark,
    surfaceContainerLow: surfaceCardDark,
    // Elevated chrome: floating map controls, dialogs, pickers. Left unset the
    // getter falls back to `surface`, which paints elevated surfaces the
    // darkest colour in the ramp instead of lifting them off it.
    surfaceContainerHigh: surfacePressDark,
    // Filled surfaces, segment tracks, dial faces. Must stay a visible step
    // above `surfaceContainerHigh`: the station dial paints its face here on
    // top of a dialog painted there.
    surfaceContainerHighest: surfaceHighlightDark,
    onSurfaceVariant: inkSecondaryDark,
    outline: contentDisabledDark,
    outlineVariant: borderDark,
  );

  static BoxDecoration floatingControl(
    ColorScheme cs, {
    BorderRadius? borderRadius,
    BoxShape shape = BoxShape.rectangle,
  }) {
    final isDark = cs.brightness == Brightness.dark;
    return BoxDecoration(
      color: isDark ? cs.surfaceContainerHigh : Colors.white,
      borderRadius: borderRadius,
      shape: shape,
      border: isDark ? Border.all(color: cs.outlineVariant) : null,
      boxShadow: isDark ? const [] : AppShadows.floating,
    );
  }

  static TextTheme _text(ColorScheme cs) => TextTheme(
    displayLarge: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 28,
      fontWeight: FontWeight.w700,
      height: 1.3,
      letterSpacing: -0.56,
      color: cs.onSurface,
    ),
    headlineLarge: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 18,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: cs.onSurface,
    ),
    titleLarge: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 24,
      fontWeight: FontWeight.w700,
      height: 1.3,
      letterSpacing: -0.48,
      color: cs.onSurface,
    ),
    titleMedium: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 16,
      fontWeight: FontWeight.w700,
      height: 1.35,
      color: cs.onSurface,
    ),
    titleSmall: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.45,
      color: cs.onSurface,
    ),
    bodyLarge: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 1.5,
      color: cs.onSurface,
    ),
    bodyMedium: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.5,
      color: cs.onSurface,
    ),
    bodySmall: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 12,
      fontWeight: FontWeight.w400,
      height: 1.4,
      letterSpacing: 0.1,
      color: cs.onSurfaceVariant,
    ),
    labelLarge: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 14,
      fontWeight: FontWeight.w700,
      height: 1.4,
      color: cs.onSurface,
    ),
    labelMedium: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 12,
      fontWeight: FontWeight.w600,
      height: 1.4,
      letterSpacing: 0.1,
      color: cs.onSurfaceVariant,
    ),
    labelSmall: TextStyle(
      fontFamily: 'IBMPlexSans',
      fontSize: 11,
      fontWeight: FontWeight.w500,
      height: 1.4,
      letterSpacing: 0.2,
      color: cs.onSurfaceVariant,
    ),
  );

  static CardThemeData _card(ColorScheme cs) => CardThemeData(
    color: cs.brightness == Brightness.light
        ? surfaceCardLight
        : surfaceCardDark,
    elevation: 1,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radiusCard),
    ),
    clipBehavior: Clip.antiAlias,
    margin: EdgeInsets.zero,
  );

  static SkeletonizerConfigData _skeleton(ColorScheme cs) =>
      SkeletonizerConfigData(
        effect: ShimmerEffect(
          baseColor: cs.surfaceContainerHighest,
          highlightColor: cs.surfaceContainer,
          duration: AppMotion.shimmerLoop,
        ),
        textBorderRadius: TextBoneBorderRadius(
          BorderRadius.circular(radiusChip),
        ),
        containersColor: cs.surfaceContainerHighest,
      );

  static ThemeData get light => _build(lightScheme);

  static ThemeData get dark => _build(darkScheme);

  static ThemeData _build(ColorScheme cs) => ThemeData(
    useMaterial3: true,
    fontFamily: 'IBMPlexSans',
    colorScheme: cs,
    extensions: [_skeleton(cs)],
    textTheme: _text(cs),
    cardTheme: _card(cs),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: BigPredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: _ReducedMotionCupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: _ReducedMotionCupertinoPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: cs.onSurface,
      titleTextStyle: _text(cs).titleLarge,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        minimumSize: const Size(64, 44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusButton),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radiusChip),
      ),
    ),
    scaffoldBackgroundColor: cs.surface,
    dividerTheme: DividerThemeData(
      space: 0,
      thickness: 0.5,
      color: cs.outlineVariant,
    ),
  );
}
