import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';

class FilterChipGroup<T> extends StatelessWidget {
  const FilterChipGroup({
    required this.options,
    required this.selected,
    required this.onToggle,
    super.key,
  });

  final Map<T, String> options;
  final Set<T> selected;
  final ValueChanged<T> onToggle;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppTheme.space8,
        children: [
          for (final entry in options.entries)
            _Chip(
              label: entry.value,
              selected: selected.contains(entry.key),
              onTap: () => onToggle(entry.key),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Pressable(
      onTap: onTap,
      semanticLabel: selected
          ? AppI18n.of(context).chipSelectedSemantics(label)
          : label,
      child: Container(
        // 30pt visual height with vertical hit-area padding to reach a 44pt
        // tappable envelope.
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(vertical: 7),
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: reduceMotion ? Duration.zero : AppMotion.short,
          curve: AppMotion.easeOut,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.space10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? cs.surfaceContainerHighest : Colors.transparent,
            borderRadius: BorderRadius.circular(AppTheme.radiusButton),
            border: Border.all(
              color: selected ? cs.primary : cs.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The check keeps its slot when unselected so toggling a chip
              // never reflows the row around it.
              Opacity(
                opacity: selected ? 1 : 0,
                child: Icon(Icons.check_rounded, size: 14, color: cs.onSurface),
              ),
              const SizedBox(width: AppTheme.space4),
              Text(
                label,
                style: AppTextStyles.bodySmall.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? cs.onSurface : cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
