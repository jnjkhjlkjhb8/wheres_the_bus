import 'package:flutter/material.dart';
import 'package:wheres_the_bus/features/feedback/view/shake_report_host.dart';
import 'package:wheres_the_bus/shared/widgets/nav_mini_bar.dart';

class MainScaffold extends StatelessWidget {
  const MainScaffold({required this.shell, super.key});

  /// The active branch navigator. Typed [Widget] (the router passes a
  /// `StatefulNavigationShell`) so tests can render the scaffold around any
  /// content.
  final Widget shell;

  @override
  Widget build(BuildContext context) =>
      ShakeReportHost(child: _buildScaffold(context));

  Widget _buildScaffold(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    body: Stack(
      children: [
        Positioned.fill(child: shell),
        const Align(alignment: Alignment.bottomCenter, child: NavMiniBar()),
      ],
    ),
  );
}
