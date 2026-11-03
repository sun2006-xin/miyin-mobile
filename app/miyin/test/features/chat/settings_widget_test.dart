import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:miyin_app/features/chat/chat_host.dart';
import 'package:miyin_app/features/chat/deepseek_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  testWidgets(
    'service selection supports keyless drafts, custom endpoint and return',
    (tester) async {
      late Directory temp;
      late ChatHost host;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('miyin-settings-');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.miyin.app/chat-secrets'),
              (_) async => null,
            );
        host = ChatHost(
          onEvent: (_) async {},
          databasePath: '${temp.path}/chat.db',
          databaseFactory: databaseFactoryFfi,
        );
        await host.loadConfiguration();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) =>
                      DeepSeekSettings(host: host, page: 'provider'),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('通义千问 · 北京地域').last);
      await tester.pumpAndSettle();
      expect(
        find.text('https://dashscope.aliyuncs.com/compatible-mode/v1'),
        findsOneWidget,
      );
      final model = find.byType(TextField).last;
      await tester.ensureVisible(model);
      await tester.enterText(model, 'qwen-plus');
      await tester.tap(find.text('保存'));
      // Saving includes real SQLite I/O. Wait for the dialog to close rather
      // than assuming disk work always completes inside a fixed 200 ms.
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
        if (find.byType(DeepSeekSettings).evaluate().isEmpty) break;
      }
      expect(find.byType(DeepSeekSettings), findsNothing);
      expect(host.provider, 'dashscope');
      expect(host.selectedModel, 'qwen-plus');
      expect(host.status['configured'], false);
      expect(tester.takeException(), null);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义兼容服务').last);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, '服务基础地址'), findsOneWidget);
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();
      expect(find.text('模型服务配置'), findsNothing);
      for (final id in ['phone', 'openai', 'anthropic', 'glm']) {
        await tester.runAsync(() async {
          if (id == 'phone') {
            await host.saveService('phone', 'Qwen3.5-2B');
          } else {
            await host.saveCloudService(id, '', 'account-model');
          }
        });
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          null,
          reason: 'Fallback settings for $id',
        );
        await tester.tap(find.text('返回'));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await host.close();
        await temp.delete(recursive: true);
      });
    },
  );
}
