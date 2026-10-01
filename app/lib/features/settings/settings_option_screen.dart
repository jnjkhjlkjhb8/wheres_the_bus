import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_card.dart';

class SettingsOptionScreen extends StatefulWidget {
  const SettingsOptionScreen({
    required this.title,
    required this.options,
    required this.initialSelected,
    super.key,
  });

  final String title;
  final List<String> options;
  final String initialSelected;

  @override
  State<SettingsOptionScreen> createState() => _SettingsOptionScreenState();
}

class _SettingsOptionScreenState extends State<SettingsOptionScreen> {
  late String _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialSelected;
  }

  void _pick(String value) {
    setState(() => _selected = value);
    context.pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: DetailAppBar(title: widget.title),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.space16,
          0,
          AppTheme.space16,
          AppTheme.space16,
        ),
        child: AppCard(
          padding: const EdgeInsets.all(AppTheme.space10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (int i = 0; i < widget.options.length; i++) ...[
                if (i > 0) const SizedBox(height: AppTheme.space10),
                _OptionRow(
                  label: widget.options[i],
                  selected: widget.options[i] == _selected,
                  onTap: () => _pick(widget.options[i]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  // Row content stays visually compact (36 logical px) inside a 44px tap
  // target — the extra 8px is transparent padding, not extra visible
  // height, so the list keeps its current density.
  static const double _visualHeight = 36;
  static const double _minTapTarget = 44;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _minTapTarget,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: (_minTapTarget - _visualHeight) / AppTheme.space2,
          ),
          child: Row(
            children: [
              Text(
                label,
                style: selected
                    ? AppTextStyles.heading2
                    : AppTextStyles.bodyLarge,
              ),
              const Spacer(),
              Opacity(
                opacity: selected ? 1 : 0,
                child: const Icon(Icons.check_rounded, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
