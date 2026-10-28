import 'dart:io';
import 'dart:convert';

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
  test(
    'web source snapshots survive reopen and remain bound to their answer',
    () async {
      final host = open();
      await host.loadHistory([]);
      final rows = [
        {
          'id': 'web-conversation',
          'messages': [
            for (final id in ['first', 'second'])
              {
                'id': id,
                'role': 'assistant',
                'status': 'complete',
                'text': '信息[网页1]',
                'webSources': [
                  {
                    'title': '来源$id',
                    'url': 'https://example.com/$id',
                    'kind': 'pageExcerpt',
                    'publishedAt': '2026-10-28',
                    'fetchedAt': '2026-10-28T01:00:00Z',
                  },
                ],
              },
          ],
        },
      ];
      await host.saveHistory(rows);
      await host.close();
      final reopened = open();
      try {
        expect(await reopened.loadHistory([]), rows);
      } finally {
        await reopened.close();
      }
    },
  );
  test(
    'local warm-up status never exposes runtime credentials to the page',
    () async {
      const local = MethodChannel('com.miyin.app/chat-local');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            local,
            (_) async => {
              'ready': true,
              'bundled': true,
              'endpoint': 'http://127.0.0.1:11438/v1',
              'key': 'runtime-test-only',
            },
          );
      final host = open();
      try {
        expect(await host.handle('chat.local.status', {}), {
          'ready': true,
          'bundled': true,
        });
        expect(await host.handle('chat.local.prepare', {}), {'ready': true});
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(local, null);
        await host.close();
      }
    },
  );
  test(
    'refreshing active vendor catalog does not replace its active model',
    () async {
      final host = open();
      await host.loadConfiguration();
      await host.saveCloudService(
        'deepseek',
        '',
        'original-model',
        typedKey: 'test-only-key',
      );
      await host.savePrivacy({'allowNetwork': true});
      await host.handle('chat.settings.catalog', {
        'service': 'deepseek',
        'model': 'new-model',
        'models': ['new-model'],
      });
      expect(host.selectedModel, 'original-model');
      expect(host.allowNetwork, true);
      expect(host.modelsFor('deepseek'), ['new-model']);
      await host.close();
    },
  );
  test(
    'visible model checkboxes persist independently from active chat model',
    () async {
      final host = open();
      await host.loadConfiguration();
      await host.saveService('phone', 'Qwen3.5-2B');
      await host.savePrivacy({'allowNetwork': true});
      final ids = List.generate(150, (i) => 'model-$i');
      await host.handle('chat.settings.catalog', {
        'service': 'openai',
        'model': ids.first,
        'models': ids,
      });
      expect(host.visibleModelsFor('openai'), isEmpty);
      await host.handle('chat.settings.visibility', {
        'services': [
          {
            'service': 'openai',
            'endpoint': 'https://api.openai.com/v1',
            'models': ['model-2', 'model-110'],
          },
          {'service': 'phone', 'endpoint': '', 'models': []},
        ],
      });
      expect(host.provider, 'phone');
      expect(host.selectedModel, 'Qwen3.5-2B');
      expect(host.allowNetwork, true);
      expect(host.visibleModelsFor('phone'), isEmpty);
      expect(host.visibleModelsFor('openai'), ['model-2', 'model-110']);
      await host.close();
      final next = open();
      await next.loadConfiguration();
      expect(next.visibleModelsFor('phone'), isEmpty);
      expect(next.visibleModelsFor('openai'), ['model-2', 'model-110']);
      expect(next.provider, 'phone');
      await next.close();
    },
  );
  test('invalid visible selections reject the entire update', () async {
    final host = open();
    await host.loadConfiguration();
    final before = host.visibleModelsFor('phone');
    await expectLater(
      host.handle('chat.settings.visibility', {
        'services': [
          {'service': 'phone', 'endpoint': '', 'models': []},
          {
            'service': 'openai',
            'endpoint': 'https://wrong.example',
            'models': ['not-added'],
          },
        ],
      }),
      throwsA(isA<ChatFailure>()),
    );
    expect(host.visibleModelsFor('phone'), before);
    await host.close();
  });
  test(
    'catalog updates do not switch service or reset current consent',
    () async {
      final host = open();
      await host.loadConfiguration();
      await host.savePrivacy({'allowNetwork': true});
      final before = host.provider;
      await host.handle('chat.settings.catalog', {
        'service': 'openai',
        'model': 'account-model',
        'models': ['account-model'],
      });
      expect(host.provider, before);
      expect(host.allowNetwork, true);
      expect(host.modelsFor('openai'), ['account-model']);
      await host.close();
      final restored = open();
      await restored.loadConfiguration();
      expect(restored.provider, before);
      expect(restored.modelsFor('openai'), ['account-model']);
      await restored.close();
    },
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
  test('conversation summaries survive reopen and remain isolated', () async {
    final host = open();
    await host.loadConfiguration();
    final db = await databaseFactoryFfi.openDatabase(path);
    await db.insert('settings', {
      'id': 'memory:a',
      'body': jsonEncode({
        'version': 2,
        'model': 'qwen3.5:4b',
        'summary': '会话A的摘要',
        'sourceQuotes': '会话A的原文',
        'covered': 2,
        'digest': 'fixture',
        'updatedAt': 123,
      }),
    });
    await host.close();
    final next = open();
    await next.loadConfiguration();
    expect(
      (await next.handle('chat.memory.get', {'conversationId': 'a'}))['memory'],
      isNotNull,
    );
    expect(
      (await next.handle('chat.memory.get', {'conversationId': 'b'}))['memory'],
      isNull,
    );
    await next.handle('chat.memory.clear', {'conversationId': 'a'});
    expect(
      (await next.handle('chat.memory.get', {'conversationId': 'a'}))['memory'],
      isNull,
    );
    await next.close();
  });
  test('long context choice and memory preference survive restart', () async {
    final host = open();
    await host.loadConfiguration();
    await host.saveService('ollama', 'qwen3.5:4b', contextWindow: 32768);
    await host.savePrivacy({'useMemory': false});
    await host.close();
    final next = open();
    await next.loadConfiguration();
    expect(next.localContextWindow, 32768);
    expect(next.useMemory, false);
    await expectLater(
      next.saveService('deepseek', 'deepseek-flash', contextWindow: 1),
      throwsA(isA<ChatFailure>()),
    );
    expect(next.provider, 'ollama');
    expect(next.localContextWindow, 32768);
    await next.close();
  });
  test(
    'cloud services keep separate encrypted keys and public configuration',
    () async {
      String? vault;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'read') return vault;
            if (call.method == 'write') vault = call.arguments as String;
            return null;
          });
      final host = open();
      await host.loadConfiguration();
      await host.saveCloudService(
        'deepseek',
        '',
        'deepseek-flash',
        typedKey: 'test-deepseek-key',
      );
      await host.savePrivacy({'allowNetwork': true});
      await host.saveCloudService(
        'dashscope',
        'ignored',
        'qwen-plus',
        typedKey: 'test-dashscope-key',
      );
      expect(host.allowNetwork, false);
      expect(host.keyFor('deepseek'), 'test-deepseek-key');
      expect(host.keyFor('dashscope'), 'test-dashscope-key');
      expect(jsonEncode(host.status), isNot(contains('test-dashscope-key')));
      final db = await databaseFactoryFfi.openDatabase(path);
      expect(
        jsonEncode(await db.query('settings')),
        isNot(contains('test-deepseek-key')),
      );
      await host.close();
      final next = open();
      await next.loadConfiguration();
      expect(next.provider, 'dashscope');
      expect(next.selectedModel, 'qwen-plus');
      expect(next.keyFor('deepseek'), 'test-deepseek-key');
      expect(next.keyFor('dashscope'), 'test-dashscope-key');
      await next.clearConfiguration(service: 'dashscope');
      expect(next.keyFor('dashscope'), null);
      expect(next.keyFor('deepseek'), 'test-deepseek-key');
      await next.close();
    },
  );
  test(
    'changing custom endpoint clears the old credential and send permission',
    () async {
      final host = open();
      await host.loadConfiguration();
      await host.saveCloudService(
        'custom',
        'https://one.example/v1/chat/completions',
        'model-a',
        typedKey: 'test-custom-key',
      );
      expect(host.endpointFor('custom'), 'https://one.example/v1');
      await host.savePrivacy({'allowNetwork': true});
      await host.saveCloudService(
        'custom',
        'https://two.example/v1',
        'model-b',
      );
      expect(host.keyFor('custom'), null);
      expect(host.allowNetwork, false);
      expect(host.status['configured'], false);
      await expectLater(
        host.saveCloudService('custom', 'http://unsafe.example', 'model'),
        throwsA(isA<ChatFailure>()),
      );
      expect(host.endpointFor('custom'), 'https://two.example/v1');
      await host.close();
    },
  );
  test(
    'deleting conversation clears derived memory without deleting another',
    () async {
      final host = open();
      await host.loadConfiguration();
      await host.loadHistory([]);
      await host.saveHistory([
        conversation('a', '原文A'),
        conversation('b', '原文B'),
      ]);
      final db = await databaseFactoryFfi.openDatabase(path);
      for (final id in ['a', 'b']) {
        await db.insert('settings', {
          'id': 'memory:$id',
          'body': jsonEncode({
            'version': 2,
            'model': 'qwen3.5:4b',
            'summary': '摘要$id',
            'sourceQuotes': '原文$id',
            'covered': 2,
            'digest': 'fixture',
            'updatedAt': 123,
          }),
        });
      }
      await host.handle('chat.memory.get', {'conversationId': 'a'});
      await host.saveHistory([conversation('b', '原文B')]);
      expect(
        (await host.handle('chat.memory.get', {
          'conversationId': 'a',
        }))['memory'],
        isNull,
      );
      expect(
        (await host.handle('chat.memory.get', {
          'conversationId': 'b',
        }))['memory'],
        isNotNull,
      );
      await host.close();
    },
  );
}
