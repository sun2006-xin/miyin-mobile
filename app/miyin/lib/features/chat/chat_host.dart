import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'deepseek_client.dart';

final class ChatHost {
  ChatHost({required this.onEvent});
  final Future<void> Function(Map<String, Object?>) onEvent;
  static const _secrets = MethodChannel('com.miyin.app/chat-secrets');
  String? _key;
  String? model;
  List<String> models = [];
  DeepSeekClient? _active;
  String? _activeId;
  Future<Database>? _database;
  Future<void> _writes = Future<void>.value();
  bool _closed = false;

  Future<void> loadConfiguration() async {
    final saved = await _secrets.invokeMethod<String>('read');
    if (saved == null) {
      _key = null;
      model = null;
      models = [];
      return;
    }
    final value = jsonDecode(saved) as Map;
    _key = value['key'] as String;
    model = value['model'] as String;
    models = (value['models'] as List).cast<String>();
  }

  Map<String, Object?> get status => {
    'configured': _key != null,
    'provider': 'DeepSeek',
    'model': model,
    'models': models,
  };

  Future<List<String>> checkKey(String key) {
    if (!RegExp(r'^[\x21-\x7e]{8,512}$').hasMatch(key)) {
      throw const ChatFailure('invalid_key', '请填写完整的 DeepSeek API Key。');
    }
    return DeepSeekClient(apiKey: key).models();
  }

  Future<void> saveConfiguration(
    String key,
    String selected,
    List<String> available,
  ) async {
    if (_active != null) {
      throw const ChatFailure('busy', '请先停止当前回答，再更改模型配置。');
    }
    if (!available.contains(selected)) {
      throw const ChatFailure('invalid_model', '请选择账户可用的模型。');
    }
    await _secrets.invokeMethod<void>(
      'write',
      jsonEncode({'key': key, 'model': selected, 'models': available}),
    );
    _key = key;
    model = selected;
    models = available;
  }

  Future<void> selectModel(String selected) async {
    if (_key == null) throw const ChatFailure('unconfigured', '请先配置 DeepSeek。');
    await saveConfiguration(_key!, selected, models);
  }

  Future<void> clearConfiguration() async {
    cancel();
    await _secrets.invokeMethod<void>('clear');
    _key = null;
    model = null;
    models = [];
  }

  Future<List<String>> checkSavedKey() async {
    final available = await checkKey(_key ?? '');
    models = available;
    return available;
  }

  Future<Map<String, Object?>> handle(
    String method,
    Map<String, Object?> params,
  ) async {
    switch (method) {
      case 'chat.status':
        await loadConfiguration();
        return status;
      case 'chat.selectModel':
        await selectModel(params['model'] as String);
        return status;
      case 'chat.start':
        return start(params);
      case 'chat.cancel':
        if (params['requestId'] == _activeId) cancel();
        return {'status': 'canceled'};
      case 'chat.history.load':
        return {'conversations': await loadHistory(params['legacy'])};
      case 'chat.history.save':
        await saveHistory(params['conversations']);
        return {'saved': true};
      default:
        throw const ChatFailure('unknown_method', '不支持的聊天操作。');
    }
  }

  Map<String, Object?> start(Map<String, Object?> params) {
    if (_closed) throw const ChatFailure('closed', '聊天页面已关闭。');
    if (_key == null || model == null) {
      throw const ChatFailure('unconfigured', '请在模型设置中配置 DeepSeek 后再发送。');
    }
    if (_active != null) throw const ChatFailure('busy', '请先等待或停止当前回答。');
    final id = params['requestId'];
    final raw = params['messages'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 160 ||
        raw is! List ||
        raw.isEmpty ||
        raw.length > 200) {
      throw const ChatFailure('invalid_request', '消息数量不合适，请新建对话。');
    }
    var length = 0;
    final messages = <Map<String, String>>[];
    for (final item in raw) {
      if (item is! Map ||
          !['user', 'assistant'].contains(item['role']) ||
          item['content'] is! String) {
        throw const ChatFailure('invalid_request', '消息格式不正确。');
      }
      final content = item['content'] as String;
      length += content.length;
      if (content.length > 32000 || length > 96000) {
        throw const ChatFailure('context_limit', '对话内容过长，请新建会话或减少附加资料。');
      }
      messages.add({'role': item['role'] as String, 'content': content});
    }
    final client = DeepSeekClient(apiKey: _key!);
    final selected = model!;
    _active = client;
    _activeId = id;
    // Let the RPC acknowledgement reach the page before streaming events.
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 40),
        () => _run(client, id, selected, messages),
      ),
    );
    return {'requestId': id, 'model': model, 'status': 'started'};
  }

  Future<void> _run(
    DeepSeekClient client,
    String id,
    String selected,
    List<Map<String, String>> messages,
  ) async {
    Future<void> emit(String type, [String? text, String? code]) async {
      if (_closed || _activeId != id) return;
      try {
        await onEvent({
          'requestId': id,
          'type': type,
          'text': text,
          'code': code,
        });
      } catch (_) {
        cancel();
      }
    }

    try {
      if (_activeId != id || _closed) return;
      await for (final text in client.complete(selected, messages)) {
        await emit('delta', text);
      }
      await emit('completed');
    } on ChatFailure catch (error) {
      await emit('failed', error.message, error.code);
    } catch (_) {
      await emit('failed', '回答未能完成，请重试。', 'failed');
    } finally {
      if (_activeId == id) {
        _active = null;
        _activeId = null;
      }
    }
  }

  void cancel() {
    _activeId = null;
    _active?.cancel();
    _active = null;
  }

  Future<Database> _db() => _database ??= () async {
    final directory = await getApplicationSupportDirectory();
    return openDatabase(
      '${directory.path}/miyin_chat.db',
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE conversations (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
        );
        await db.execute('CREATE TABLE metadata (id TEXT PRIMARY KEY)');
      },
    );
  }();

  List<Map<String, Object?>> _validateHistory(Object? input) {
    if (input is! List ||
        input.length > 2000 ||
        jsonEncode(input).length > 8 * 1024 * 1024) {
      throw const ChatFailure('history_limit', '聊天记录过多，无法保存本次更改。');
    }
    final result = <Map<String, Object?>>[];
    final ids = <String>{};
    for (final item in input) {
      if (item is! Map ||
          item['id'] is! String ||
          (item['id'] as String).length > 160 ||
          item['messages'] is! List ||
          !ids.add(item['id'] as String)) {
        throw const ChatFailure('invalid_history', '聊天记录格式不正确。');
      }
      result.add(Map<String, Object?>.from(item));
    }
    return result;
  }

  Future<List<Object?>> loadHistory(Object? legacy) async {
    final db = await _db();
    await _writes;
    if ((await db.query(
      'metadata',
      where: 'id = ?',
      whereArgs: ['legacy_imported'],
    )).isEmpty) {
      final imported = _validateHistory(legacy ?? []);
      await db.transaction((tx) async {
        for (final row in imported) {
          await tx.insert('conversations', {
            'id': row['id'],
            'body': jsonEncode(row),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await tx.insert('metadata', {'id': 'legacy_imported'});
      });
    }
    return (await db.query('conversations'))
        .map((row) => jsonDecode(row['body'] as String))
        .toList();
  }

  Future<void> saveHistory(Object? input) {
    final rows = _validateHistory(input);
    final write = _writes.then((_) async {
      final db = await _db();
      await db.transaction((tx) async {
        await tx.delete('conversations');
        for (final row in rows) {
          await tx.insert('conversations', {
            'id': row['id'],
            'body': jsonEncode(row),
          });
        }
      });
    });
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<void> close() async {
    _closed = true;
    cancel();
    await _writes;
    if (_database != null) await (await _database!).close();
  }
}
