import 'package:flutter_test/flutter_test.dart';
import 'package:true_local_time/main.dart';

void main() {
  group('projectOrtho', () {
    test('the centred meridian on the equator lands at the globe centre', () {
      final p = projectOrtho(0, 50, 50, 100, 100, 80);
      expect(p.x, closeTo(100, 1e-9));
      expect(p.y, closeTo(100, 1e-9));
      expect(p.cosc, closeTo(1, 1e-9));
    });

    test('the north pole lands at the top of the globe', () {
      final p = projectOrtho(90, 123, 0, 100, 100, 80);
      expect(p.x, closeTo(100, 1e-9));
      expect(p.y, closeTo(20, 1e-9));
    });

    test('a point 90 degrees east sits on the right limb', () {
      final p = projectOrtho(0, 90, 0, 100, 100, 80);
      expect(p.x, closeTo(180, 1e-9));
      expect(p.y, closeTo(100, 1e-9));
      expect(p.cosc, closeTo(0, 1e-9));
    });

    test('the antipodal point is on the far hemisphere', () {
      final p = projectOrtho(0, 180, 0, 100, 100, 80);
      expect(p.cosc, lessThan(0));
    });

    test('longitude wraps across the antimeridian', () {
      final near = projectOrtho(0, 179, -179, 100, 100, 80);
      // 179 and -179 are only 2 degrees apart, so the point stays visible
      // and close to the centre rather than wrapping the long way around.
      expect(near.cosc, greaterThan(0.99));
    });
  });
}
