import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/miyin/automatic_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.miyin.app/automatic-update');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  testWidgets(
    'waits until the first screen is usable before checking updates',
    (tester) async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      final service = AutomaticUpdateService(
        isAndroid: true,
        initialCheckDelay: const Duration(seconds: 20),
        statusPollInterval: const Duration(seconds: 30),
      );
      addTearDown(() {
        service.dispose();
        messenger.setMockMethodCallHandler(channel, null);
      });

      await service.start((_) {});
      expect(calls, isEmpty);

      await tester.pump(const Duration(seconds: 19));
      expect(calls, isEmpty);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(calls, ['scheduleCheck']);

      await tester.pump(const Duration(seconds: 9));
      await tester.pump();
      expect(calls, ['scheduleCheck']);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(calls, ['scheduleCheck', 'status']);
    },
  );

  testWidgets('dispose cancels an update check that has not started', (
    tester,
  ) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    final service = AutomaticUpdateService(
      isAndroid: true,
      initialCheckDelay: const Duration(seconds: 20),
      statusPollInterval: const Duration(seconds: 30),
    );
    addTearDown(() {
      service.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    });

    await service.start((_) {});
    service.dispose();
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();

    expect(calls, isEmpty);
  });
}
