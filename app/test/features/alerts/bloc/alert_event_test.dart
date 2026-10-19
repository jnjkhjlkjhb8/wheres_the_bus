import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/errors/app_error.dart';
import 'package:wheres_the_bus/data/models/alert_models.dart';
import 'package:wheres_the_bus/features/alerts/bloc/alert_event.dart';

void main() {
  const tra = AlertSource(AlertSourceKind.tra);
  const thsr = AlertSource(AlertSourceKind.thsr);
  const vm = AlertViewModel(message: 'm', level: AlertSeverity.red);

  test('events without payload carry no props', () {
    expect(const AlertStarted().props, isEmpty);
    expect(const AlertAllRead().props, isEmpty);
    expect(const AlertStarted(), const AlertStarted());
  });

  test('AlertReceived compares source and alerts', () {
    expect(const AlertReceived(tra, [vm]), const AlertReceived(tra, [vm]));
    expect(
      const AlertReceived(tra, [vm]),
      isNot(const AlertReceived(thsr, [vm])),
    );
    expect(const AlertReceived(tra, [vm]), isNot(const AlertReceived(tra, [])));
  });

  test('AlertScopeChanged compares the scope', () {
    expect(const AlertScopeChanged({'a'}), const AlertScopeChanged({'a'}));
    expect(
      const AlertScopeChanged({'a'}),
      isNot(const AlertScopeChanged({'b'})),
    );
  });

  test('message events compare their payload', () {
    expect(const AlertDismissed('a'), const AlertDismissed('a'));
    expect(const AlertDismissed('a'), isNot(const AlertDismissed('b')));
    expect(const AlertAllDismissed(['a']), const AlertAllDismissed(['a']));
    expect(
      const AlertAllDismissed(['a']),
      isNot(const AlertAllDismissed(['b'])),
    );
    expect(const AlertRestored(['a']), const AlertRestored(['a']));
    expect(const AlertRestored(['a']), isNot(const AlertRestored(['b'])));
    expect(const AlertMarkedRead('a'), const AlertMarkedRead('a'));
    expect(const AlertMarkedRead('a'), isNot(const AlertMarkedRead('b')));
  });

  test('AlertStreamFailed compares error and source', () {
    const failed = AlertStreamFailed(OfflineError(), source: tra);
    expect(failed, const AlertStreamFailed(OfflineError(), source: tra));
    expect(failed, isNot(const AlertStreamFailed(TimeoutError(), source: tra)));
    expect(
      failed,
      isNot(const AlertStreamFailed(OfflineError(), source: thsr)),
    );
    expect(failed, isNot(const AlertStreamFailed(OfflineError())));
  });

  test('AlertStreamRecovered compares source', () {
    expect(
      const AlertStreamRecovered(source: tra),
      const AlertStreamRecovered(source: tra),
    );
    expect(
      const AlertStreamRecovered(source: tra),
      isNot(const AlertStreamRecovered(source: thsr)),
    );
    expect(
      const AlertStreamRecovered(source: tra),
      isNot(const AlertStreamRecovered()),
    );
  });

  test('AlertConfigChanged compares the csv', () {
    expect(const AlertConfigChanged('a'), const AlertConfigChanged('a'));
    expect(const AlertConfigChanged('a'), isNot(const AlertConfigChanged('b')));
  });
}
