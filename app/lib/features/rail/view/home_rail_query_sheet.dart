import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/router/app_routes.dart';
import 'package:wheres_the_bus/features/rail/widgets/rail_query_sheet.dart';

/// The rail query form as hosted inside the home sheet. Unlike the rail screen,
/// which shows results inline, this hands an O/D query off to `/rail` as an
/// auto-submitting location, and a train query to `/rail/train/...`.
class HomeRailQuerySheet extends StatelessWidget {
  const HomeRailQuerySheet({this.preset, super.key});

  final RailQueryPreset? preset;

  void _onSubmit(BuildContext context, RailQuerySubmission submission) {
    switch (submission) {
      case RailOdQuerySubmission():
        unawaited(
          context.push(
            AppRoutes.railLocation(
              system: submission.system,
              originName: submission.originName,
              originId: submission.originId,
              destName: submission.destName,
              destId: submission.destId,
              date: submission.date,
              isDeparture: submission.isDeparture,
              submit: true,
            ),
          ),
        );
      case RailTrainQuerySubmission():
        unawaited(
          context.push(
            AppRoutes.railTrain(
              submission.trainNo,
              system: submission.system,
              date: submission.date,
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return RailQuerySheetContent(
      preset: preset,
      onSubmit: (submission) => _onSubmit(context, submission),
      // Pops this form off the sheet's nested navigator, back to the nearby
      // list it was opened from.
      onBack: () => Navigator.of(context).maybePop(),
    );
  }
}
