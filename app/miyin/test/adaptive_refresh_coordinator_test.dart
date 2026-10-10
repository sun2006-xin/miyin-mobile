import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/core/adaptive_refresh_coordinator.dart';

void main() {
  test(
    'requests high refresh for active work and debounces the idle return',
    () async {
      final requests = <bool>[];
      final coordinator = AdaptiveRefreshCoordinator(
        requestHighRefresh: (active) async {
          requests.add(active);
        },
        idleDelay: const Duration(milliseconds: 40),
      );
      addTearDown(coordinator.dispose);

      coordinator.onActivitySignal('active');
      await Future<void>.delayed(Duration.zero);
      expect(requests, <bool>[true]);

      coordinator.onActivitySignal('idle');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.onActivitySignal('active');
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(requests, <bool>[true]);

      coordinator.onActivitySignal('idle');
      await Future<void>.delayed(const Duration(milliseconds: 55));
      expect(requests, <bool>[true, false]);
    },
  );

  test(
    'dispose restores the system refresh policy when still active',
    () async {
      final requests = <bool>[];
      final coordinator = AdaptiveRefreshCoordinator(
        requestHighRefresh: (active) async {
          requests.add(active);
        },
      );

      coordinator.onActivitySignal('active');
      await Future<void>.delayed(Duration.zero);
      coordinator.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(requests, <bool>[true, false]);
    },
  );
}
