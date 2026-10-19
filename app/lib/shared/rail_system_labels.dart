import 'package:wheres_the_bus/features/rail/bloc/rail_event.dart';

String railSystemLabel(RailSystem system) =>
    system == RailSystem.thsr ? '高鐵' : '台鐵';

/// Inverse of [railSystemLabel]. Anything unrecognised — including the empty
/// subtitle of a favorite saved before the label was stored — reads as TRA,
/// the larger network.
RailSystem railSystemFromLabel(String label) =>
    label == '高鐵' ? RailSystem.thsr : RailSystem.tra;
