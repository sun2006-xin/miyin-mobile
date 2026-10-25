import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/chat_host.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Directory temporary;
  late String path;
  const channel = MethodChannel('com.miyin.app/chat-secrets');
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('miyin-chat-test-');
    path = '${temporary.path}/chat.db';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });
  ChatHost open() => ChatHost(
    onEvent: (_) async {},
    databasePath: path,
    databaseFactory: databaseFactoryFfi,
  );
  Map<String, Object?> conversation(String id, String text) => {
    'id': id,
    'title': id,
    'messages': [
      {
        'id': 'm',
        'role': 'user',
        'text': text,
        'status': 'complete',
        'createdAt': 123,
      },
    ],
  };

  test('models and privacy persist without storing a credential', () async {
    final first = open();
    await first.loadConfiguration();
    expect(first.allowNetwork, isFalse);
    await first.saveDraft('custom-model');
    await first.savePrivacy({'sendHistory': false, 'saveLocalHistory': false});
    await first.close();
    final next = open();
    await next.loadConfiguration();
    expect(next.model, 'custom-model');
    expect(next.status['configured'], false);
    expect(next.sendHistory, false);
    expect(next.saveLocalHistory, false);
    await next.close();
  });
  test(
    'legacy history preference is respected during first initialization',
    () async {
      final host = open();
      await host.loadConfiguration(legacySaveHistory: false);
      expect(host.saveLocalHistory, false);
      await host.close();
    },
  );
  test(
    'legacy history import is idempotent; updates and deletion survive restart',
    () async {
      final host = open();
      expect(await host.loadHistory([conversation('a', 'old')]), hasLength(1));
      await host.saveHistory([
        conversation('a', 'new'),
        conversation('b', 'another'),
      ]);
      await host.saveHistory([conversation('b', 'another')]);
      await host.close();
      final next = open();
      final rows = await next.loadHistory([
        conversation('a', 'must-not-return'),
      ]);
      expect(rows, hasLength(1));
      expect((rows.single as Map)['id'], 'b');
      await next.saveHistory([]);
      expect(await next.loadHistory([]), isEmpty);
      await next.close();
    },
  );
  test('schema 1 upgrade keeps existing conversation rows', () async {
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE conversations (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
          );
          await db.execute('CREATE TABLE metadata (id TEXT PRIMARY KEY)');
          await db.insert('metadata', {'id': 'legacy_imported'});
          await db.insert('conversations', {
            'id': 'old',
            'body': '{"id":"old","messages":[]}',
          });
        },
      ),
    );
    await old.close();
    final host = open();
    await host.loadConfiguration();
    expect(await host.loadHistory([]), hasLength(1));
    await host.saveDraft('deepseek-flash');
    await host.close();
  });
  test(
    'invalid model ids and duplicate conversations fail explicitly',
    () async {
      final host = open();
      await expectLater(
        host.saveDraft('../unsafe'),
        throwsA(isA<ChatFailure>()),
      );
      expect(
        () =>
            host.saveHistory([conversation('a', '1'), conversation('a', '2')]),
        throwsA(isA<ChatFailure>()),
      );
      await host.close();
    },
  );
  test(
    'without permission or key generation cannot reach a provider',
    () async {
      final host = open();
      expect(
        () => host.start({}),
        throwsA(
          isA<ChatFailure>().having((e) => e.code, 'code', 'network_disabled'),
        ),
      );
      await host.savePrivacy({'allowNetwork': true});
      expect(
        () => host.start({}),
        throwsA(
          isA<ChatFailure>().having((e) => e.code, 'code', 'unconfigured'),
        ),
      );
      await host.close();
    },
  );
}
