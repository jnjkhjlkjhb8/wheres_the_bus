import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/theme/app_text_styles.dart';
import 'package:wheres_the_bus/app/theme/app_theme.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_bloc.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_event.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_state.dart';
import 'package:wheres_the_bus/l10n/app_i18n.dart';
import 'package:wheres_the_bus/shared/motion/app_motion.dart';
import 'package:wheres_the_bus/shared/motion/pressable.dart';
import 'package:wheres_the_bus/shared/widgets/app_bars.dart';
import 'package:wheres_the_bus/shared/widgets/app_input.dart';
import 'package:wheres_the_bus/shared/widgets/app_snackbar.dart';

/// Remaining-character threshold below which the counter appears. Above it the
/// limit is not information the rider needs, so it stays out of the way.
const _counterThreshold = 200;

class FeedbackScreen extends StatelessWidget {
  const FeedbackScreen({this.fromScreen, super.key});

  final String? fromScreen;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => FeedbackBloc()
        ..add(
          FeedbackOpened(
            screen: fromScreen ?? '',
            locale: Localizations.localeOf(context).toLanguageTag(),
          ),
        ),
      child: const FeedbackView(),
    );
  }
}

/// The page's content, separated from [FeedbackScreen] so tests can mount it
/// over a [FeedbackBloc] built on a fake repository.
@visibleForTesting
class FeedbackView extends StatefulWidget {
  const FeedbackView({super.key});

  @override
  State<FeedbackView> createState() => _FeedbackViewState();
}

class _FeedbackViewState extends State<FeedbackView> {
  final _controller = TextEditingController();
  FeedbackCategory _category = FeedbackCategory.routeData;

  @override
  void initState() {
    super.initState();
    // The submit control and the counter both read the field, so the page
    // rebuilds on every keystroke rather than only when the bloc emits.
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  String get _body => _controller.text.trim();

  void _selectCategory(FeedbackCategory category) {
    if (category == _category) return;
    setState(() => _category = category);
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    context.read<FeedbackBloc>().add(
      FeedbackSubmitted(category: _category, body: _body),
    );
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Scaffold(
      appBar: DetailAppBar(title: AppI18n.of(context).feedbackTitle),
      body: BlocConsumer<FeedbackBloc, FeedbackState>(
        listenWhen: (previous, current) => previous.status != current.status,
        listener: (context, state) {
          // Fired on arrival rather than on the tap: the buzz means the report
          // is stored, and a failed submission must not feel like a success.
          if (state.status == FeedbackStatus.sent) {
            unawaited(HapticService.instance.mediumTap());
          }
        },
        builder: (context, state) => AnimatedSwitcher(
          duration: reduceMotion ? Duration.zero : AppMotion.medium,
          switchInCurve: AppMotion.easeOut,
          switchOutCurve: AppMotion.easeOut,
          transitionBuilder: (child, animation) {
            final fade = FadeTransition(opacity: animation, child: child);
            if (reduceMotion) return fade;
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.03),
                end: Offset.zero,
              ).animate(animation),
              child: fade,
            );
          },
          child: state.status == FeedbackStatus.sent && state.receipt != null
              ? _ReceiptPanel(
                  key: const ValueKey('sent'),
                  receipt: state.receipt!,
                )
              : _Composer(
                  key: const ValueKey('composing'),
                  controller: _controller,
                  category: _category,
                  onCategoryChanged: _selectCategory,
                  onSubmit: _submit,
                  body: _body,
                  state: state,
                ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.category,
    required this.onCategoryChanged,
    required this.onSubmit,
    required this.body,
    required this.state,
    super.key,
  });

  final TextEditingController controller;
  final FeedbackCategory category;
  final ValueChanged<FeedbackCategory> onCategoryChanged;
  final VoidCallback onSubmit;
  final String body;
  final FeedbackState state;

  /// Sending needs something to send and something to attach it to: the
  /// diagnostics disclosure is a promise, so the control waits for it to
  /// resolve rather than letting a report leave without it.
  bool get _canSubmit =>
      body.isNotEmpty &&
      body.runes.length <= feedbackBodyLimit &&
      state.diagnostics != null &&
      !state.submitting;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppTheme.space16),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.space20,
              0,
              AppTheme.space20,
              AppTheme.space8,
            ),
            children: [
              _CategoryPicker(value: category, onChanged: onCategoryChanged),
              const SizedBox(height: AppTheme.space20),
              AppInput(
                label: AppI18n.of(context).feedbackBodyLabel,
                hint: category.hintOf(AppI18n.of(context)),
                controller: controller,
                keyboardType: TextInputType.multiline,
                // Opens tall enough to look like the main event on this page
                // rather than a field to fill in, then grows with the text.
                minLines: 6,
                maxLines: 12,
                maxLength: feedbackBodyLimit,
              ),
              // Counted in runes, matching what the server counts, so the
              // number the rider sees is the one that will be enforced.
              _Counter(length: controller.text.runes.length),
              const SizedBox(height: AppTheme.space16),
              _DiagnosticsDisclosure(diagnostics: state.diagnostics),
            ],
          ),
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.space20,
              AppTheme.space4,
              AppTheme.space20,
              0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded, size: 16, color: cs.error),
                const SizedBox(width: AppTheme.space6),
                Expanded(
                  child: Text(
                    state.error!.messageOf(AppI18n.of(context)),
                    style: AppTextStyles.bodySmall.copyWith(color: cs.error),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          // The button sits on the bottom edge of the page, so it has to clear
          // the gesture bar itself.
          padding: EdgeInsets.fromLTRB(
            AppTheme.space20,
            AppTheme.space12,
            AppTheme.space20,
            AppTheme.space20 + MediaQuery.paddingOf(context).bottom,
          ),
          child: _SubmitButton(
            enabled: _canSubmit,
            busy: state.submitting,
            onTap: onSubmit,
          ),
        ),
      ],
    );
  }
}

/// Four chips rather than a segmented control: the labels are long enough that
/// four fixed-width segments would clip under the large-text setting, and a
/// Wrap simply takes a second line instead.
class _CategoryPicker extends StatelessWidget {
  const _CategoryPicker({required this.value, required this.onChanged});

  final FeedbackCategory value;
  final ValueChanged<FeedbackCategory> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppI18n.of(context).feedbackCategoryPrompt,
          style: AppTextStyles.bodySmall.copyWith(
            fontWeight: FontWeight.w600,
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppTheme.space10),
        Wrap(
          spacing: AppTheme.space8,
          runSpacing: AppTheme.space8,
          children: [
            for (final category in FeedbackCategory.values)
              _CategoryChip(
                category: category,
                selected: category == value,
                onTap: () => onChanged(category),
              ),
          ],
        ),
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.category,
    required this.selected,
    required this.onTap,
  });

  final FeedbackCategory category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Pressable(
        onTap: onTap,
        semanticLabel: category.labelOf(AppI18n.of(context)),
        minTapSize: 44,
        child: AnimatedContainer(
          duration: reduceMotion ? Duration.zero : AppMotion.press,
          curve: AppMotion.easeOut,
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.space14,
            vertical: 9,
          ),
          decoration: BoxDecoration(
            // Selection is carried by the ink fill, not by a second hue: the
            // accent is the only one this interface has.
            color: selected ? cs.onSurface : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppTheme.radiusButton),
          ),
          child: Text(
            category.labelOf(AppI18n.of(context)),
            style: AppTextStyles.bodyRegular.copyWith(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? cs.surface : cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// Appears only near the ceiling. A counter that is always on tells the rider
/// their message is being measured from the first character, which is not the
/// relationship this screen wants.
class _Counter extends StatelessWidget {
  const _Counter({required this.length});

  final int length;

  @override
  Widget build(BuildContext context) {
    final remaining = feedbackBodyLimit - length;
    if (remaining > _counterThreshold) {
      return const SizedBox(height: AppTheme.space8);
    }
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.space6),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text(
          AppI18n.of(context).feedbackCharsLeft(remaining),
          style: AppTextStyles.memo.copyWith(
            color: remaining <= 0 ? cs.error : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// What the app attaches, shown before it is sent rather than described in a
/// policy elsewhere. Riders are anonymous here; the point of the disclosure is
/// that there is nothing in it they have not seen.
class _DiagnosticsDisclosure extends StatelessWidget {
  const _DiagnosticsDisclosure({required this.diagnostics});

  final FeedbackDiagnostics? diagnostics;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final summary = diagnostics?.summary ?? const <String>[];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.space12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppI18n.of(context).feedbackAttached,
            style: AppTextStyles.bodySmall.copyWith(
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.space4),
          Text(
            summary.isEmpty
                ? AppI18n.of(context).feedbackReadingDevice
                : summary.join(' · '),
            // Secondary ink, not full ink: spelled out, these values run three
            // lines, and at full weight the disclosure becomes the loudest
            // thing on a screen whose subject is the rider's own sentence.
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.enabled,
    required this.busy,
    required this.onTap,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Pressable(
      enabled: enabled,
      onTap: onTap,
      semanticLabel: AppI18n.of(context).feedbackSubmitSemantics,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? cs.onSurface : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppTheme.radiusButton),
        ),
        child: busy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: cs.surface,
                ),
              )
            : Text(
                AppI18n.of(context).feedbackSubmit,
                style: AppTextStyles.bodyLarge.copyWith(
                  fontWeight: FontWeight.w700,
                  color: enabled ? cs.surface : cs.onSurfaceVariant,
                ),
              ),
      ),
    );
  }
}

/// The terminal state. It states the case number and, because this release has
/// no in-app reply, says so plainly rather than implying an answer is coming.
class _ReceiptPanel extends StatelessWidget {
  const _ReceiptPanel({required this.receipt, super.key});

  final FeedbackReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.space20,
        AppTheme.space8,
        AppTheme.space20,
        AppTheme.space20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A confirmation is shorter than a form, and the page keeps the
          // height it had. Centring the block spreads the leftover space above
          // and below instead of pooling all of it under the text.
          const Spacer(),
          Icon(Icons.check_circle_rounded, size: 32, color: cs.onSurface),
          const SizedBox(height: AppTheme.space12),
          Text(AppI18n.of(context).feedbackSent, style: AppTextStyles.heading1),
          const SizedBox(height: AppTheme.space8),
          Text(
            AppI18n.of(context).feedbackThanks,
            style: AppTextStyles.bodyLarge.copyWith(color: cs.onSurface),
          ),
          const SizedBox(height: AppTheme.space16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppTheme.space12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppTheme.radiusCard),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppI18n.of(context).feedbackReceiptLabel,
                  style: AppTextStyles.bodySmall.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppTheme.space4),
                SelectableText(
                  receipt.reference,
                  style: AppTextStyles.memo.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.space12),
          Text(
            AppI18n.of(context).feedbackNoReplyNote,
            style: AppTextStyles.bodySmall.copyWith(color: cs.onSurfaceVariant),
          ),
          const Spacer(),
          SizedBox(height: 8 + MediaQuery.paddingOf(context).bottom),
          _DoneButton(reference: receipt.reference),
        ],
      ),
    );
  }
}

class _DoneButton extends StatelessWidget {
  const _DoneButton({required this.reference});

  final String reference;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Pressable(
            onTap: () {
              unawaited(
                Clipboard.setData(ClipboardData(text: reference)),
              );
              unawaited(HapticService.instance.lightTap());
              AppSnackbar.show(
                context,
                AppI18n.of(context).feedbackReceiptCopied,
                type: SnackType.success,
              );
            },
            semanticLabel: AppI18n.of(context).feedbackCopyReceiptSemantics,
            child: Container(
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTheme.radiusButton),
                border: Border.all(color: cs.outline),
              ),
              child: Text(
                AppI18n.of(context).feedbackCopyReceipt,
                style: AppTextStyles.bodyLarge.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppTheme.space12),
        Expanded(
          child: Pressable(
            onTap: () => context.pop(),
            semanticLabel: AppI18n.of(context).commonDone,
            child: Container(
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cs.onSurface,
                borderRadius: BorderRadius.circular(AppTheme.radiusButton),
              ),
              child: Text(
                AppI18n.of(context).commonDone,
                style: AppTextStyles.bodyLarge.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.surface,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
