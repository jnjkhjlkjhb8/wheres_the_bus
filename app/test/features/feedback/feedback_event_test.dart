import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/feedback_models.dart';
import 'package:wheres_the_bus/features/feedback/bloc/feedback_event.dart';

void main() {
  test('FeedbackOpened compares screen and locale', () {
    const base = FeedbackOpened(screen: '/home', locale: 'en');
    expect(base, const FeedbackOpened(screen: '/home', locale: 'en'));
    expect(base, isNot(const FeedbackOpened(screen: '/go', locale: 'en')));
    expect(base, isNot(const FeedbackOpened(screen: '/home', locale: 'zh')));
  });

  test('FeedbackSubmitted compares category and body', () {
    const base = FeedbackSubmitted(
      category: FeedbackCategory.eta,
      body: 'late',
    );
    expect(
      base,
      const FeedbackSubmitted(category: FeedbackCategory.eta, body: 'late'),
    );
    expect(
      base,
      isNot(
        const FeedbackSubmitted(category: FeedbackCategory.crash, body: 'late'),
      ),
    );
    expect(
      base,
      isNot(
        const FeedbackSubmitted(category: FeedbackCategory.eta, body: 'early'),
      ),
    );
  });
}
