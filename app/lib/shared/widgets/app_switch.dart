import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/shared/widgets/native_controls.dart';

class AppSwitch extends StatelessWidget {
  const AppSwitch({
    required this.value,
    required this.onChanged,
    super.key,
    this.label,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;

  // Flutter-drawn, not a hosted UISwitch: these sit in scrolling lists that
  // pass under blurred headers, where a platform view shows through the blur
  // as an opaque block.
  Widget get _cupertino => CupertinoSwitch(value: value, onChanged: onChanged);

  Widget get _material => Switch(
    value: value,
    onChanged: onChanged,
    thumbIcon: WidgetStateProperty.resolveWith(
      (states) => Icon(
        states.contains(WidgetState.selected)
            ? Icons.check_rounded
            : Icons.close_rounded,
        size: 16,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final sw = usesUiKitControls ? _cupertino : _material;
    if (label == null) return sw;
    // Merged so a screen reader reads one control ("label, on") instead of a
    // bare text and a separate unlabeled switch.
    return MergeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged != null ? () => onChanged!(!value) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label!, style: AppTextStyles.bodyLarge),
              sw,
            ],
          ),
        ),
      ),
    );
  }
}
