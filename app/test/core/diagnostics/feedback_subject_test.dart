import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/diagnostics/feedback_subject.dart';

Widget _stack(List<String> labels) {
  Widget child = const SizedBox.shrink();
  for (final label in labels.reversed) {
    child = FeedbackSubjectScope(label: label, child: child);
  }
  return child;
}

void main() {
  setUp(FeedbackSubject.reset);

  testWidgets('the innermost mounted page is the subject', (tester) async {
    await tester.pumpWidget(_stack(['307 · 往 板橋', '臺北車站(忠孝)']));
    expect(FeedbackSubject.current, '臺北車站(忠孝)');

    // Popping the stop hands the subject back to the route underneath.
    await tester.pumpWidget(_stack(['307 · 往 板橋']));
    expect(FeedbackSubject.current, '307 · 往 板橋');

    await tester.pumpWidget(const SizedBox.shrink());
    expect(FeedbackSubject.current, isNull);
  });

  testWidgets('a page still loading its name claims nothing, then renames', (
    tester,
  ) async {
    await tester.pumpWidget(_stack(['']));
    expect(FeedbackSubject.current, isNull);

    await tester.pumpWidget(_stack(['307']));
    expect(FeedbackSubject.current, '307');

    await tester.pumpWidget(_stack(['307 · 往 板橋']));
    expect(FeedbackSubject.current, '307 · 往 板橋');

    // Losing the name again withdraws the claim.
    await tester.pumpWidget(_stack(['']));
    expect(FeedbackSubject.current, isNull);
  });
}
