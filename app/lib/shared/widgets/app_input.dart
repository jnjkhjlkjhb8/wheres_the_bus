import 'package:flutter/material.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';

class AppInput extends StatelessWidget {
  const AppInput({
    required this.label,
    super.key,
    this.hint,
    this.helper,
    this.error,
    this.controller,
    this.onChanged,
    this.obscureText = false,
    this.keyboardType,
    this.prefixIcon,
    this.suffixIcon,
    this.minLines,
    this.maxLines = 1,
    this.maxLength,
    this.autofocus = false,
  });

  final String label;
  final String? hint;
  final String? helper;
  final String? error;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final bool obscureText;
  final TextInputType? keyboardType;
  final Widget? prefixIcon;
  final Widget? suffixIcon;

  /// Height floor for a multiline field, in lines. Paired with [maxLines] it
  /// gives a box that opens at a useful size and then grows with the text.
  final int? minLines;

  /// Line ceiling. The default of 1 keeps every existing single-line call
  /// site unchanged; pass null to let the field grow without bound.
  final int? maxLines;

  /// Hard input ceiling. Material's own counter is suppressed: a field that
  /// reports its length from the first character reads as a form to satisfy,
  /// so call sites surface remaining length on their own terms.
  final int? maxLength;
  final bool autofocus;

  OutlineInputBorder _border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        borderSide: BorderSide(color: color, width: width),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      obscureText: obscureText,
      keyboardType: keyboardType,
      minLines: minLines,
      maxLines: maxLines,
      maxLength: maxLength,
      autofocus: autofocus,
      style: AppTextStyles.bodyLarge,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        // A multiline field's label must sit at the top of the box rather than
        // vertically centred against several lines of text.
        alignLabelWithHint: (maxLines ?? 2) > 1,
        counterText: '',
        helperText: error == null ? helper : null,
        errorText: error,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        border: _border(cs.outline),
        enabledBorder: _border(cs.outline),
        focusedBorder: _border(cs.primary, width: 2),
        errorBorder: _border(cs.error),
        focusedErrorBorder: _border(cs.error, width: 2),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space16,
          vertical: AppTheme.space12,
        ),
        labelStyle: AppTextStyles.bodyRegular.copyWith(
          color: cs.onSurfaceVariant,
        ),
        helperStyle: AppTextStyles.bodySmall.copyWith(
          color: cs.onSurfaceVariant,
        ),
        errorStyle: AppTextStyles.bodySmall.copyWith(color: cs.error),
        hintStyle: AppTextStyles.bodyRegular.copyWith(
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}
