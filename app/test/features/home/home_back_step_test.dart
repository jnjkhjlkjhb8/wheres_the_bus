import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/features/home/home_screen.dart';

void main() {
  test('back unwinds the sheet before it unwinds the app', () {
    // A pushed sheet page outranks everything: it is the thing the rider is
    // looking at, and it is on top of an expanded sheet by definition.
    expect(
      homeBackStep(
        sheetPagePushed: true,
        sheetAbovePeek: true,
        routeCanPop: true,
      ),
      HomeBackStep.popSheetPage,
    );
    expect(
      homeBackStep(
        sheetPagePushed: false,
        sheetAbovePeek: true,
        routeCanPop: true,
      ),
      HomeBackStep.collapseSheet,
    );
    expect(
      homeBackStep(
        sheetPagePushed: false,
        sheetAbovePeek: false,
        routeCanPop: true,
      ),
      HomeBackStep.popRoute,
    );
    // Nothing left to unwind — and since `canPop: false` stops the platform
    // from exiting on its own, this step has to do it.
    expect(
      homeBackStep(
        sheetPagePushed: false,
        sheetAbovePeek: false,
        routeCanPop: false,
      ),
      HomeBackStep.exitApp,
    );
  });
}
