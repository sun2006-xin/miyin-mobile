import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

import 'deepseek_client.dart';

final class ChatHost {
  ChatHost({
    required this.onEvent,
    this.databasePath,
    DatabaseFactory? databaseFactory,
  }) : _databaseFactory = databaseFactory;
  final String? databasePath;
  final DatabaseFactory? _databaseFactory;
  final Future<void> Function(Map<String, Object?>) onEvent;
  static const _secrets = MethodChannel('com.miyin.app/chat-secrets');
  String? _key;
  static const presetModels = ['deepseek-flash', 'deepseek-v4-pro'];
  String? model = presetModels.first;
  List<String> models = [...presetModels];
  bool allowNetwork = false;
  bool sendHistory = true;
  bool saveLocalHistory = true;
  bool connectionChecked = false;
  DeepSeekClient? _active;
  String? _activeId;
  Future<Database>? _database;
  Future<void> _writes = Future<void>.value();
  bool _closed = false;
  Map<String, String> _storedBodies = {};

  Future<void> loadConfiguration({bool? legacySaveHistory}) async {
    final db = await _db();
    final rows = await db.query(
      'settings',
      where: 'id = ?',
      whereArgs: ['config'],
    );
    if (rows.isNotEmpty) {
      final config = jsonDecode(rows.first['body'] as String) as Map;
      model = config['model'] as String? ?? presetModels.first;
      models = (config['models'] as List?)?.cast<String>() ?? [...presetModels];
      allowNetwork = config['allowNetwork'] == true;
      sendHistory = config['sendHistory'] != false;
      saveLocalHistory = config['saveLocalHistory'] != false;
      connectionChecked = config['connectionChecked'] == true;
    }
    if (rows.isEmpty && legacySaveHistory != null) {
      saveLocalHistory = legacySaveHistory;
    }
    final saved = await _secrets.invokeMethod<String>('read');
    if (saved == null) {
      _key = null;
      return;
    }
    final value = jsonDecode(saved) as Map;
    _key = value['key'] as String;
    if (rows.isEmpty) {
      model = value['model'] as String? ?? model;
      models = (value['models'] as List?)?.cast<String>() ?? models;
    }
  }

  Map<String, Object?> get status => {
    'configured': _key != null,
    'provider': 'DeepSeek',
    'model': model,
    'models': models,
    'connectionChecked': connectionChecked && _key != null,
    'privacy': {
      'allowNetwork': allowNetwork,
      'sendHistory': sendHistory,
      'saveLocalHistory': saveLocalHistory,
    },
  };

  Future<void> _saveSettings() async {
    final db = await _db();
    await db.insert('settings', {
      'id': 'config',
      'body': jsonEncode({
        'model': model,
        'models': models,
        'allowNetwork': allowNetwork,
        'sendHistory': sendHistory,
        'saveLocalHistory': saveLocalHistory,
        'connectionChecked': connectionChecked,
      }),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveDraft(String selected) async {
    if (_active != null) throw const ChatFailure('busy', '请先停止当前回答。');
    if (!RegExp(r'^[a-zA-Z0-9._:-]{1,128}$').hasMatch(selected)) {
      throw const ChatFailure('invalid_model', '模型 ID 只能包含字母、数字、点、横线或冒号。');
    }
    model = selected;
    if (!models.contains(selected)) models = [...models, selected];
    await _saveSettings();
  }

  Future<void> savePrivacy(Map<String, Object?> values) async {
    if (_active != null &&
        (values.containsKey('allowNetwork') ||
            values.containsKey('sendHistory'))) {
      throw const ChatFailure('busy', '请先停止当前回答。');
    }
    if (values['allowNetwork'] is bool) {
      allowNetwork = values['allowNetwork'] as bool;
    }
    if (values['sendHistory'] is bool) {
      sendHistory = values['sendHistory'] as bool;
    }
    if (values['saveLocalHistory'] is bool) {
      saveLocalHistory = values['saveLocalHistory'] as bool;
    }
    await _saveSettings();
  }

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
    connectionChecked = true;
    await _saveSettings();
  }

  Future<void> selectModel(String selected) async {
    await saveDraft(selected);
  }

  Future<void> clearConfiguration() async {
    cancel();
    await _secrets.invokeMethod<void>('clear');
    _key = null;
    connectionChecked = false;
    await _saveSettings();
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
        await loadConfiguration(
          legacySaveHistory: params['saveHistory'] is bool
              ? params['saveHistory'] as bool
              : null,
        );
        return status;
      case 'chat.selectModel':
        await selectModel(params['model'] as String);
        return status;
      case 'chat.privacy':
        await savePrivacy(params);
        return status;
      case 'chat.copy':
        final text = params['text'];
        if (text is! String || text.length > 256000) {
          throw const ChatFailure('invalid_text', '要复制的内容过长。');
        }
        await Clipboard.setData(ClipboardData(text: text));
        return {'copied': true};
      case 'chat.share':
        final text = params['text'];
        if (text is! String || text.isEmpty || text.length > 256000) {
          throw const ChatFailure('invalid_text', '要分享的内容为空或过长。');
        }
        await const MethodChannel('com.miyin.app/chat-actions')
            .invokeMethod<void>('shareText', text);
        return {'opened': true};
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
    if (!allowNetwork) {
      throw const ChatFailure('network_disabled', 'AI 隐私设置中尚未允许发送至远程模型。');
    }
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
    if (!sendHistory && messages.isNotEmpty) {
      final lastUser = messages.lastWhere((item) => item['role'] == 'user');
      messages
        ..clear()
        ..add(lastUser);
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
    final path =
        databasePath ??
        '${(await getApplicationSupportDirectory()).path}/miyin_chat.db';
    return (_databaseFactory ?? sqlite.databaseFactory).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE conversations (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
          );
          await db.execute('CREATE TABLE metadata (id TEXT PRIMARY KEY)');
          await db.execute(
            'CREATE TABLE settings (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
          );
        },
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) {
            await db.execute(
              'CREATE TABLE settings (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
            );
          }
        },
      ),
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
    final saved = await db.query('conversations');
    _storedBodies = {
      for (final row in saved) row['id'] as String: row['body'] as String,
    };
    return saved.map((row) => jsonDecode(row['body'] as String)).toList();
  }

  Future<void> saveHistory(Object? input) {
    final rows = _validateHistory(input);
    final write = _writes.then((_) async {
      final db = await _db();
      final bodies = {
        for (final row in rows) row['id'] as String: jsonEncode(row),
      };
      await db.transaction((tx) async {
        for (final id in _storedBodies.keys.where(
          (id) => !bodies.containsKey(id),
        )) {
          await tx.delete('conversations', where: 'id = ?', whereArgs: [id]);
        }
        for (final entry in bodies.entries) {
          if (_storedBodies[entry.key] == entry.value) continue;
          await tx.insert('conversations', {
            'id': entry.key,
            'body': entry.value,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });
      _storedBodies = bodies;
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
