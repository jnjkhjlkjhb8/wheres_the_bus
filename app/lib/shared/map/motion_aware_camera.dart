import 'package:google_maps_flutter/google_maps_flutter.dart';

extension MotionAwareCamera on GoogleMapController {
  /// Snaps instead of tweening when the system asks for reduced motion.
  Future<void> moveOrAnimate(CameraUpdate update, {required bool reduced}) =>
      reduced ? moveCamera(update) : animateCamera(update);
}
