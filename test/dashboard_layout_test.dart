import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jiejiebox_flutter/views/dashboard/dashboard_layout.dart';

/// Expectations copied from FlClash v0.9.3
/// `test/views/dashboard/layout_test.dart:19-38`, so the vendored layout rules
/// are checked against upstream's own asserted behaviour.
void main() {
  DashboardDensity of(double width, double height) =>
      DashboardDensity.of(Size(width, height));

  test('dashboard density matches upstream expectations', () {
    expect(of(1220, 900), DashboardDensity.standard);
    expect(of(1220, 824), DashboardDensity.standard);
    expect(of(1220, 823), DashboardDensity.compact);
    expect(of(1220, 500), DashboardDensity.compact);
    expect(of(1039, 900), DashboardDensity.compact);
    expect(of(860, 900), DashboardDensity.compact);
    expect(of(859, 900), DashboardDensity.standard);
    expect(of(640, 900), DashboardDensity.standard);
    expect(of(640, 823), DashboardDensity.compact);
    expect(of(639, 900), DashboardDensity.mobile);
  });

  test('dashboard columns split at 860', () {
    expect(dashboardColumnsOf(860), 4);
    expect(dashboardColumnsOf(859), 2);
  });

  test('mobile dashboard keeps a 560 content column, 16 min side', () {
    expect(dashboardMobileSideOf(375), 16);
    expect(dashboardMobileSideOf(600), 20);
    expect(dashboardMobileSideOf(1280), 360);
  });
}
