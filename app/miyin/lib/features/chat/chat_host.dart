import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite/sqflite.dart' as sqlite;

import 'deepseek_client.dart';
import 'ollama_client.dart';
import 'conversation_memory.dart';
import 'public_page_reader.dart';
import 'cloud_service.dart';
import 'phone_llm_client.dart';
import 'chat_search_context.dart';
import 'web_search.dart';

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
  final cloudServices = Map<String, CloudService>.of(CloudService.defaults);
  final Map<String, Map<String, String>> _serviceSecrets = {};
  final Map<String, Map<String, Object?>> _visibleModelProfiles = {};
  static final _serviceIds = [
    'phone',
    'ollama',
    'deepseek',
    ...CloudService.defaults.keys,
  ];
  String _visibilityEndpoint(String service) =>
      ['phone', 'ollama'].contains(service) ? '' : endpointFor(service);
  List<String> visibleModelsFor(String service) {
    final saved = _visibleModelProfiles[service];
    if (saved == null || saved['endpoint'] != _visibilityEndpoint(service))
      return [];
    return (saved['models'] as List)
        .whereType<String>()
        .where(modelsFor(service).contains)
        .toList();
  }

  String? keyFor(String service) {
    if (service == 'deepseek') return _key;
    final secret = _serviceSecrets[service];
    if (secret == null ||
        secret['endpoint'] != cloudServices[service]?.endpoint)
      return null;
    return secret['key'];
  }

  String get serviceLabel => isPhone
      ? '手机内置模型 · Qwen3.5-2B'
      : isLocal
      ? '电脑本地模型 · Ollama'
      : provider == 'deepseek'
      ? 'DeepSeek'
      : cloudServices[provider]!.label;
  List<String> modelsFor(String service) => service == 'phone'
      ? ['Qwen3.5-2B']
      : service == 'ollama'
      ? localModels
      : service == 'deepseek'
      ? models
      : cloudServices[service]!.models;
  String modelFor(String service) => service == 'phone'
      ? 'Qwen3.5-2B'
      : service == 'ollama'
      ? localModel
      : service == 'deepseek'
      ? model ?? ''
      : cloudServices[service]!.model;
  String endpointFor(String service) => ['phone', 'ollama'].contains(service)
      ? ''
      : service == 'deepseek'
      ? 'https://api.deepseek.com'
      : cloudServices[service]!.endpoint;
  DeepSeekClient cloudClient(String service, String key, String endpoint) =>
      DeepSeekClient(
        apiKey: key,
        baseUrl: endpoint,
        serviceName: service == 'deepseek'
            ? 'DeepSeek'
            : cloudServices[service]!.label,
        deepSeekOptions: service == 'deepseek',
        anthropic: service == 'anthropic',
      );
  static const presetModels = ['deepseek-flash', 'deepseek-v4-pro'];
  String? model = presetModels.first;
  List<String> models = [...presetModels];
  bool allowNetwork = false;
  bool sendHistory = true;
  bool saveLocalHistory = true;
  bool useMemory = true;
  String webMode = 'off';
  WebSearch? _search;
  int localContextWindow = 8192;
  final Map<String, MemorySnapshot> _memories = {};
  bool connectionChecked = false;
  String provider = 'deepseek';
  String localModel = 'qwen3.5:4b';
  List<String> localModels = ['qwen3.5:4b'];
  bool thinking = false;
  bool get isLocal => provider == 'ollama';
  bool get isPhone => provider == 'phone';
  String? get selectedModel =>
      modelFor(provider).isEmpty ? null : modelFor(provider);
  ChatClient? _active;
  String? _activeId;
  Future<Database>? _database;
  Future<void> _writes = Future<void>.value();
  bool _closed = false;
  PublicPageReader? _pageReader;
  String? _pageRequestId;
  Map<String, String> _storedBodies = {};

  Future<void> loadConfiguration({bool? legacySaveHistory}) async {
    _visibleModelProfiles.clear();
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
      useMemory = config['useMemory'] != false;
      webMode = ['off', 'auto', 'always'].contains(config['webMode'])
          ? config['webMode'] as String
          : 'off';
      localContextWindow =
          config['localContextWindow'] is int &&
              [8192, 16384, 32768].contains(config['localContextWindow'])
          ? config['localContextWindow'] as int
          : 8192;
      connectionChecked = config['connectionChecked'] == true;
      provider =
          [
            'phone',
            'ollama',
            'deepseek',
            ...CloudService.defaults.keys,
          ].contains(config['provider'])
          ? config['provider'] as String
          : 'deepseek';
      final profiles = config['cloudServices'];
      if (profiles is Map) {
        for (final id in CloudService.defaults.keys) {
          final restored = CloudService.restore(id, profiles[id]);
          if (restored != null) cloudServices[id] = restored;
        }
      }
      localModel = config['localModel'] as String? ?? 'qwen3.5:4b';
      localModels =
          (config['localModels'] as List?)?.cast<String>() ?? ['qwen3.5:4b'];
      thinking = config['thinking'] == true;
      final visible = config['visibleModelProfiles'];
      if (visible is Map) {
        for (final id in _serviceIds) {
          final row = visible[id];
          if (row is Map &&
              row['endpoint'] is String &&
              row['models'] is List &&
              (row['models'] as List).length <= 2000 &&
              (row['models'] as List).every(
                (value) => value is String && _validModelId(value),
              )) {
            _visibleModelProfiles[id] = {
              'endpoint': row['endpoint'],
              'models': List<String>.from(row['models'] as List),
            };
          }
        }
      }
    }
    // Upgrade old installations with only the active model and bundled model
    // visible, rather than exposing every model returned by a vendor.
    for (final id in _serviceIds) {
      _visibleModelProfiles.putIfAbsent(
        id,
        () => {
          'endpoint': _visibilityEndpoint(id),
          'models': id == 'phone' || (rows.isNotEmpty && provider == id)
              ? [modelFor(id)]
              : <String>[],
        },
      );
    }
    if (rows.isEmpty && legacySaveHistory != null) {
      saveLocalHistory = legacySaveHistory;
    }
    final saved = await _secrets.invokeMethod<String>('read');
    if (saved == null) {
      _key = null;
      _serviceSecrets.clear();
      return;
    }
    final value = jsonDecode(saved) as Map;
    _key = value['key'] as String?;
    _serviceSecrets.clear();
    final keys = value['serviceKeys'];
    if (keys is Map) {
      for (final id in CloudService.defaults.keys) {
        final item = keys[id];
        if (item is Map &&
            item['key'] is String &&
            item['endpoint'] is String) {
          _serviceSecrets[id] = {
            'key': item['key'] as String,
            'endpoint': item['endpoint'] as String,
          };
        }
      }
    }
    if (rows.isEmpty) {
      model = value['model'] as String? ?? model;
      models = (value['models'] as List?)?.cast<String>() ?? models;
    }
  }

  Map<String, Object?> get status => {
    'configured':
        isPhone ||
        isLocal ||
        (keyFor(provider) != null && selectedModel != null),
    'cloudConfigured': !isPhone && !isLocal && keyFor(provider) != null,
    'provider': serviceLabel,
    'providerId': provider,
    'model': selectedModel,
    'models': modelsFor(provider),
    'thinking': thinking,
    'localContextWindow': localContextWindow,
    'connectionChecked':
        !isPhone &&
        !isLocal &&
        keyFor(provider) != null &&
        (provider == 'deepseek'
            ? connectionChecked
            : cloudServices[provider]!.checked),
    'privacy': {
      'allowNetwork': allowNetwork,
      'sendHistory': sendHistory,
      'saveLocalHistory': saveLocalHistory,
      'useMemory': useMemory,
      'webMode': webMode,
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
        'useMemory': useMemory,
        'webMode': webMode,
        'localContextWindow': localContextWindow,
        'connectionChecked': connectionChecked,
        'provider': provider,
        'cloudServices': {
          for (final entry in cloudServices.entries)
            entry.key: entry.value.toJson(),
        },
        'localModel': localModel,
        'localModels': localModels,
        'thinking': thinking,
        'visibleModelProfiles': _visibleModelProfiles,
      }),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> saveDraft(String selected) async {
    if (_active != null) throw const ChatFailure('busy', '请先停止当前回答。');
    if (!_validModelId(selected)) {
      throw const ChatFailure('invalid_model', '模型 ID 只能包含字母、数字、点、横线或冒号。');
    }
    if (isPhone) {
      if (selected != 'Qwen3.5-2B')
        throw const ChatFailure('invalid_model', '请选择内置模型。');
    } else if (isLocal) {
      localModel = selected;
      if (!localModels.contains(selected))
        localModels = [...localModels, selected];
    } else if (provider != 'deepseek') {
      final old = cloudServices[provider]!;
      cloudServices[provider] = CloudService(
        old.id,
        old.label,
        old.endpoint,
        selected,
        {...old.models, selected}.toList(),
        checked: old.checked,
      );
    } else {
      model = selected;
      if (!models.contains(selected)) models = [...models, selected];
    }
    await _saveSettings();
  }

  Future<List<String>> checkLocalModels() => OllamaClient().models();

  static bool _validModelId(String value) =>
      value.length <= 128 &&
      RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._:-]*(/[a-zA-Z0-9][a-zA-Z0-9._:-]*)*$')
          .hasMatch(value);

  Future<void> saveService(
    String service,
    String selected, {
    bool deepThinking = false,
    int contextWindow = 8192,
    List<String>? available,
  }) async {
    if (_active != null) throw const ChatFailure('busy', '请先停止当前回答。');
    if (![
      'phone',
      'deepseek',
      'ollama',
      ...CloudService.defaults.keys,
    ].contains(service))
      throw const ChatFailure('invalid_provider', '不支持该模型服务。');
    if (!_validModelId(selected))
      throw const ChatFailure('invalid_model', '请填写正确的模型 ID。');
    if (![8192, 16384, 32768].contains(contextWindow))
      throw const ChatFailure('invalid_context', '请选择支持的对话长度。');
    if (provider != service) allowNetwork = false;
    provider = service;
    if (service == 'ollama') localContextWindow = contextWindow;
    // Thinking is supported by this local adapter only in this increment.
    thinking = ['phone', 'ollama'].contains(service) && deepThinking;
    if (service == 'ollama' && available != null) localModels = available;
    await saveDraft(selected);
  }

  Future<void> savePrivacy(Map<String, Object?> values) async {
    if (_active != null &&
        (values.containsKey('allowNetwork') ||
            values.containsKey('sendHistory') ||
            values.containsKey('useMemory') ||
            values.containsKey('webMode'))) {
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
    if (values['useMemory'] is bool) useMemory = values['useMemory'] as bool;
    if (values.containsKey('webMode')) {
      if (!['off', 'auto', 'always'].contains(values['webMode']))
        throw const ChatFailure('invalid_mode', '请选择支持的联网方式。');
      webMode = values['webMode'] as String;
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
    _key = key;
    await _writeSecrets();
    model = selected;
    models = available;
    connectionChecked = true;
    await _saveSettings();
  }

  Future<void> selectModel(String selected) async {
    await saveDraft(selected);
  }

  Future<void> clearConfiguration({String? service}) async {
    cancel();
    final target = service ?? provider;
    if (target == 'deepseek') {
      _key = null;
      connectionChecked = false;
    } else {
      _serviceSecrets.remove(target);
      final old = cloudServices[target];
      if (old != null)
        cloudServices[target] = CloudService(
          old.id,
          old.label,
          old.endpoint,
          old.model,
          old.models,
        );
    }
    await _writeSecrets();
    await _saveSettings();
  }

  Future<void> _writeSecrets() => _secrets.invokeMethod<void>(
    'write',
    jsonEncode({
      'key': _key,
      'model': model,
      'models': models,
      'serviceKeys': _serviceSecrets,
    }),
  );

  Future<List<String>> checkCloudModels(
    String service,
    String endpoint,
    String typedKey,
  ) {
    final normalized = CloudService.endpointFor(service, endpoint);
    final key = typedKey.trim().isNotEmpty
        ? typedKey.trim()
        : (service == 'deepseek' || endpointFor(service) == normalized
              ? keyFor(service)
              : null);
    if (key == null || !RegExp(r'^[\x21-\x7e]{8,512}$').hasMatch(key)) {
      throw const ChatFailure('invalid_key', '请填写这个服务的完整 API Key；更换地址后需要重新填写。');
    }
    return cloudClient(service, key, normalized).models();
  }

  Future<void> saveCloudService(
    String service,
    String endpoint,
    String selected, {
    String typedKey = '',
    List<String>? available,
    bool checked = false,
    bool activate = true,
  }) async {
    if (_active != null) throw const ChatFailure('busy', '请先停止当前回答。');
    final normalized = CloudService.endpointFor(service, endpoint);
    final destinationChanged =
        provider != service || endpointFor(service) != normalized;
    if (!_validModelId(selected))
      throw const ChatFailure('invalid_model', '请填写正确的模型 ID。');
    final key = typedKey.trim();
    if (key.isNotEmpty && !RegExp(r'^[\x21-\x7e]{8,512}$').hasMatch(key))
      throw const ChatFailure('invalid_key', '请填写完整 API Key。');
    final ids = {...?available, selected}.toList();
    if (ids.length > 2000 || ids.any((id) => !_validModelId(id)))
      throw const ChatFailure('invalid_model', '模型列表包含无效 ID。');
    if (service == 'deepseek') {
      if (key.isNotEmpty) _key = key;
      if (activate) model = selected;
      models = ids;
      connectionChecked = checked;
    } else {
      if (key.isNotEmpty)
        _serviceSecrets[service] = {'endpoint': normalized, 'key': key};
      if (key.isEmpty && cloudServices[service]!.endpoint != normalized)
        _serviceSecrets.remove(service);
      final old = cloudServices[service]!;
      cloudServices[service] = CloudService(
        service,
        old.label,
        normalized,
        activate ? selected : old.model,
        ids,
        checked: checked,
      );
    }
    await _writeSecrets();
    if (activate) {
      if (destinationChanged) allowNetwork = false;
      provider = service;
      thinking = false;
    }
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
      case 'chat.settings':
        return settingsSnapshot;
      case 'chat.settings.visibility':
        final rows = params['services'];
        if (rows is! List || rows.length > _serviceIds.length) {
          throw const ChatFailure('invalid_request', '显示列表格式不正确。');
        }
        final updates = <String, Map<String, Object?>>{};
        for (final row in rows) {
          if (row is! Map ||
              !_serviceIds.contains(row['service']) ||
              updates.containsKey(row['service']) ||
              row['models'] is! List) {
            throw const ChatFailure('invalid_model', '请勾选已添加的模型。');
          }
          final id = row['service'] as String, ids = row['models'] as List;
          if (row['endpoint'] != _visibilityEndpoint(id) ||
              ids.length > 2000 ||
              ids.any(
                (value) => value is! String || !modelsFor(id).contains(value),
              )) {
            throw const ChatFailure('invalid_model', '模型列表或服务地址已更新，请重新打开设置。');
          }
          updates[id] = {
            'endpoint': _visibilityEndpoint(id),
            'models': ids.cast<String>().toSet().toList(),
          };
        }
        _visibleModelProfiles.addAll(updates);
        await _saveSettings();
        return settingsSnapshot;
      case 'chat.settings.catalog':
        final service = params['service'];
        final selected = params['model'];
        final available = params['models'];
        if (service is! String ||
            ![
              'ollama',
              'deepseek',
              ...CloudService.defaults.keys,
            ].contains(service) ||
            selected is! String ||
            available is! List ||
            available.any((id) => id is! String)) {
          throw const ChatFailure('invalid_request', '请填写正确的服务和模型列表。');
        }
        if (service == 'ollama') {
          if (available.length > 2000 ||
              available.any((id) => !_validModelId(id as String))) {
            throw const ChatFailure('invalid_model', '模型列表格式不正确。');
          }
          localModels = available.cast<String>().toSet().toList();
          await _saveSettings();
          return settingsSnapshot;
        }
        await saveCloudService(
          service,
          params['endpoint'] as String? ?? '',
          selected,
          available: available.cast<String>(),
          checked: false,
          activate: false,
        );
        return settingsSnapshot;
      case 'chat.settings.save':
        final service = params['service'];
        final selected = params['model'];
        if (service is! String || selected is! String)
          throw const ChatFailure('invalid_request', '请选择服务和模型。');
        if (![
          'phone',
          'ollama',
          'deepseek',
          ...CloudService.defaults.keys,
        ].contains(service))
          throw const ChatFailure('invalid_provider', '请选择支持的模型服务。');
        if (params['models'] is List &&
            (params['models'] as List).any((id) => id is! String))
          throw const ChatFailure('invalid_model', '模型列表格式不正确。');
        if (['phone', 'ollama'].contains(service)) {
          await saveService(
            service,
            selected,
            deepThinking: params['thinking'] == true,
            contextWindow: params['contextWindow'] is int
                ? params['contextWindow'] as int
                : 8192,
          );
        } else {
          await saveCloudService(
            service,
            params['endpoint'] is String ? params['endpoint'] as String : '',
            selected,
            available: params['models'] is List
                ? (params['models'] as List).whereType<String>().toList()
                : modelsFor(service),
          );
        }
        return settingsSnapshot;
      case 'chat.settings.check':
        final service = params['service'];
        if (service is! String ||
            ![
              'phone',
              'ollama',
              'deepseek',
              ...CloudService.defaults.keys,
            ].contains(service))
          throw const ChatFailure('invalid_provider', '请选择服务。');
        if (service == 'phone')
          return {
            'models': ['Qwen3.5-2B'],
            ...await PhoneLlmClient.channel.invokeMapMethod<String, Object?>(
                  'status',
                ) ??
                {},
          };
        final available = service == 'ollama'
            ? await checkLocalModels()
            : await checkCloudModels(
                service,
                params['endpoint'] as String? ?? '',
                '',
              );
        if (service == 'ollama') {
          localModels = available;
          await _saveSettings();
        }
        return {'models': available};
      case 'chat.local.status':
        final local = await PhoneLlmClient.channel
            .invokeMapMethod<String, Object?>('status');
        return {
          'ready': local?['ready'] == true,
          'bundled': local?['bundled'] == true,
        };
      case 'chat.local.prepare':
        await PhoneLlmClient.channel.invokeMethod<Object?>('prepare');
        return {'ready': true};
      case 'chat.web.read':
        if (_closed || _active != null || _pageReader != null) {
          throw const ChatFailure('busy', '请先停止当前操作，再读取网页。');
        }
        final url = params['url'], requestId = params['requestId'];
        if (params['allowOnce'] != true ||
            url is! String ||
            requestId is! String ||
            requestId.isEmpty ||
            requestId.length > 160) {
          throw const ChatFailure('web_permission', '请主动允许本次读取公开网页。');
        }
        final reader = PublicPageReader();
        _pageReader = reader;
        _pageRequestId = requestId;
        try {
          return await reader.read(url);
        } finally {
          if (identical(_pageReader, reader)) {
            _pageReader = null;
            _pageRequestId = null;
          }
        }
      case 'chat.web.cancel':
        if (params['requestId'] == _pageRequestId) _pageReader?.cancel();
        return {'canceled': true};
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
      case 'chat.openUrl':
        final value = params['url'];
        final url = value is String && value.length <= 4096
            ? Uri.tryParse(value)
            : null;
        if (url == null ||
            !['http', 'https'].contains(url.scheme) ||
            url.host.isEmpty ||
            url.userInfo.isNotEmpty ||
            RegExp(r'[\x00-\x20]').hasMatch(value as String)) {
          throw const ChatFailure('invalid_url', '只支持打开普通网页链接。');
        }
        await const MethodChannel('com.miyin.app/chat-actions')
            .invokeMethod<void>('openUrl', url.toString());
        return {'opened': true};
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
      case 'chat.memory.get':
        final memory = await _readMemory(_conversationId(params));
        return {'memory': memory?.toJson()};
      case 'chat.memory.clear':
        if (_active != null)
          throw const ChatFailure('busy', '请先停止当前回答，再清除会话记忆。');
        final conversationId = _conversationId(params);
        _memories.remove(conversationId);
        await _writes;
        await (await _db()).delete(
          'settings',
          where: 'id = ?',
          whereArgs: ['memory:$conversationId'],
        );
        return {'cleared': true};
      default:
        throw const ChatFailure('unknown_method', '不支持的聊天操作。');
    }
  }

  Map<String, Object?> start(Map<String, Object?> params) {
    if (_closed) throw const ChatFailure('closed', '聊天页面已关闭。');
    if (!allowNetwork && !isPhone) {
      throw const ChatFailure('network_disabled', 'AI 隐私设置中尚未允许发送至所选模型服务。');
    }
    if ((!isPhone && !isLocal && keyFor(provider) == null) ||
        selectedModel == null) {
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
        raw.length > (isLocal ? 2000 : 200)) {
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
      if (content.length > 32000 || length > (isLocal ? 512000 : 96000)) {
        throw const ChatFailure('context_limit', '对话内容过长，请新建会话或减少附加资料。');
      }
      messages.add({'role': item['role'] as String, 'content': content});
    }
    if (messages.last['role'] != 'user')
      throw const ChatFailure('invalid_request', '请先输入本轮问题。');
    if (!sendHistory && messages.isNotEmpty) {
      final lastUser = messages.lastWhere((item) => item['role'] == 'user');
      messages
        ..clear()
        ..add(lastUser);
    }
    final selected = selectedModel!;
    final query = params['searchQuery'];
    final searchQuery = query is String && WebSearch.needed(webMode, query)
        ? query.trim()
        : null;
    if (searchQuery != null &&
        (searchQuery.isEmpty || searchQuery.length > 500))
      throw const ChatFailure('search_query', '请把搜索问题控制在 500 字符内。');
    final conversationId = params['conversationId'] is String
        ? _conversationId(params)
        : null;
    final compress =
        isLocal && sendHistory && useMemory && conversationId != null;
    final prepared = isPhone
        ? PhoneLlmClient.prepareContext(selected, messages)
        : isLocal && !compress
        ? OllamaClient.prepareContext(
            selected,
            messages,
            windowTokens: localContextWindow,
          )
        : null;
    final requestMessages = prepared?.messages ?? messages;
    final ChatClient client = isPhone
        ? PhoneLlmClient(
            thinking: thinking,
            onReasoning: () {
              if (!_closed && _activeId == id) {
                unawaited(
                  onEvent({
                    'requestId': id,
                    'type': 'progress',
                    'text': '正在深度思考，可关闭深度思考以更快回答…',
                  }).catchError((Object _) {
                    if (_activeId == id) cancel();
                  }),
                );
              }
            },
          )
        : isLocal
        ? OllamaClient(thinking: thinking, windowTokens: localContextWindow)
        : cloudClient(provider, keyFor(provider)!, endpointFor(provider));
    _active = client;
    _activeId = id;
    // Let the RPC acknowledgement reach the page before streaming events.
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 40),
        () => _run(
          client,
          id,
          selected,
          requestMessages,
          compress ? conversationId : null,
          searchQuery,
          prepared?.omitted ?? 0,
        ),
      ),
    );
    return {
      'requestId': id,
      'model': selected,
      'provider': provider,
      'status': 'started',
      'contextOmitted': prepared?.omitted ?? 0,
      'contextMode': 'conversation',
    };
  }

  Future<void> _run(
    ChatClient client,
    String id,
    String selected,
    List<Map<String, String>> messages,
    String? conversationId,
    String? searchQuery,
    int previouslyOmitted,
  ) async {
    final phone = client is PhoneLlmClient;
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
      if (phone) await emit('progress', '正在处理本机对话…');
      if (conversationId != null) {
        void ensureActive() {
          if (_closed || _activeId != id)
            throw const ChatFailure('canceled', '已停止整理会话记忆。');
        }

        final context = await ConversationMemory.prepare(
          model: selected,
          windowTokens: localContextWindow,
          messages: messages,
          cached: await _readMemory(conversationId),
          ensureActive: ensureActive,
          progress: (done, total) =>
              emit('progress', '正在整理较早对话（$done/$total）…'),
          summarize: (previous, chunk) async {
            ensureActive();
            client.cancel();
            final summarizer = OllamaClient(windowTokens: localContextWindow);
            client = summarizer;
            _active = summarizer;
            var summary = '';
            await for (final text in summarizer.complete(
              selected,
              [
                {
                  'role': 'user',
                  'content': jsonEncode({'旧摘要': previous, '新增对话': chunk}),
                },
              ],
              systemPrompt: ConversationMemory.summaryInstructions,
              maxOutput: 512,
            )) {
              ensureActive();
              summary += text;
            }
            ensureActive();
            return summary;
          },
          checkpoint: (memory) async {
            ensureActive();
            _memories[conversationId] = memory;
            if (saveLocalHistory) {
              final write = _writes.then((_) async {
                ensureActive();
                final db = await _db();
                ensureActive();
                await db.transaction((tx) async {
                  ensureActive();
                  await tx.insert('settings', {
                    'id': 'memory:$conversationId',
                    'body': jsonEncode(memory.toJson()),
                  }, conflictAlgorithm: ConflictAlgorithm.replace);
                  ensureActive();
                });
              });
              _writes = write.catchError((Object _) {});
              await write;
            }
          },
        );
        ensureActive();
        messages = context.messages;
        if (context.snapshot != null) {
          await emit(
            'memory',
            '本轮参考会话摘要、关键原文摘录和最近 ${context.recentCount} 条原文，完整历史仍保留。',
          );
        }
        ensureActive();
        client.cancel();
        client = OllamaClient(
          thinking: thinking,
          windowTokens: localContextWindow,
        );
        _active = client;
        await emit('progress', '正在生成回答…');
        ensureActive();
      }
      if (searchQuery != null) {
        final search = WebSearch();
        _search = search;
        try {
          final sources = await search.search(
            searchQuery,
            phone: phone,
            progress: (text) => emit('progress', text),
          );
          if (_closed || _activeId != id) return;
          await emit(
            'sources',
            jsonEncode(
              sources
                  .map(
                    (row) => {
                      for (final key in [
                        'title',
                        'url',
                        'publishedAt',
                        'fetchedAt',
                        'kind',
                      ])
                        key: row[key],
                    },
                  )
                  .toList(),
            ),
          );
          if (phone) {
            final prepared = ChatSearchContext.preparePhone(
              selected,
              messages,
              sources,
              previouslyOmitted: previouslyOmitted,
            );
            messages = prepared.messages;
            if (prepared.additionalOmitted > 0) {
              await emit('context', prepared.notice, '${prepared.omitted}');
            }
          } else {
            messages = messages
                .map((row) => Map<String, String>.of(row))
                .toList();
            messages.last['content'] =
                '${messages.last['content']}${WebSearch.material(sources, phone: false)}';
          }
          await emit('progress', '已取得来源，正在生成回答…');
        } finally {
          if (identical(_search, search)) _search = null;
        }
      }
      await for (final text in client.complete(selected, messages)) {
        await emit('delta', text);
      }
      // Release the operation before announcing completion: a listener may
      // immediately send the next turn from the completion callback.
      if (_activeId == id) _active = null;
      await emit('completed');
    } on ChatFailure catch (error) {
      if (_activeId == id) _active = null;
      await emit('failed', error.message, error.code);
    } catch (_) {
      if (_activeId == id) _active = null;
      await emit('failed', '回答未能完成，请重试。', 'failed');
    } finally {
      if (_activeId == id) {
        _active = null;
        _activeId = null;
      }
    }
  }

  void cancel() {
    _search?.cancel();
    _search = null;
    _activeId = null;
    _active?.cancel();
    _active = null;
  }

  String _conversationId(Map<String, Object?> params) {
    final value = params['conversationId'];
    if (value is! String || value.isEmpty || value.length > 160) {
      throw const ChatFailure('invalid_request', '会话标识不正确。');
    }
    return value;
  }

  Future<MemorySnapshot?> _readMemory(String id) async {
    if (_memories.containsKey(id)) return _memories[id];
    if (!saveLocalHistory) return null;
    await _writes;
    final rows = await (await _db()).query(
      'settings',
      where: 'id = ?',
      whereArgs: ['memory:$id'],
    );
    if (rows.isEmpty) return null;
    try {
      final memory = MemorySnapshot.fromJson(
        jsonDecode(rows.first['body'] as String),
      );
      if (memory != null) _memories[id] = memory;
      return memory;
    } catch (_) {
      return null;
    }
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
          await tx.delete(
            'settings',
            where: 'id = ?',
            whereArgs: ['memory:$id'],
          );
          _memories.remove(id);
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
    _pageReader?.cancel();
    cancel();
    await _writes;
    if (_database != null) await (await _database!).close();
  }

  Map<String, Object?> get settingsSnapshot => {
    'status': status,
    'services': [
      {
        'id': 'phone',
        'label': '手机内置模型',
        'hint': 'Qwen3.5-2B · 本机运行，无需密钥',
        'model': 'Qwen3.5-2B',
        'models': ['Qwen3.5-2B'],
        'visibleModels': visibleModelsFor('phone'),
        'hasKey': false,
        'endpoint': '',
      },
      {
        'id': 'ollama',
        'label': '电脑本地模型',
        'hint': '通过 USB 连接电脑 Ollama',
        'model': localModel,
        'models': localModels,
        'visibleModels': visibleModelsFor('ollama'),
        'hasKey': false,
        'endpoint': '',
      },
      {
        'id': 'deepseek',
        'label': 'DeepSeek',
        'hint': '云端服务',
        'model': model,
        'models': models,
        'visibleModels': visibleModelsFor('deepseek'),
        'hasKey': _key != null,
        'endpoint': 'https://api.deepseek.com',
      },
      for (final value in cloudServices.values)
        {
          'id': value.id,
          'label': value.label,
          'hint': '兼容文字聊天接口',
          'model': value.model,
          'models': value.models,
          'visibleModels': visibleModelsFor(value.id),
          'hasKey': keyFor(value.id) != null,
          'endpoint': value.endpoint,
        },
    ],
  };

  Future<void> saveCredential(
    String service,
    String endpoint,
    String key,
  ) async {
    if (_active != null) throw const ChatFailure('busy', '请先停止当前回答。');
    final normalized = CloudService.endpointFor(service, endpoint);
    if (provider == service && endpointFor(service) != normalized)
      allowNetwork = false;
    if (key.isNotEmpty && !RegExp(r'^[\x21-\x7e]{8,512}$').hasMatch(key))
      throw const ChatFailure('invalid_key', '请填写完整的 API Key。');
    if (service == 'deepseek') {
      _key = key.isEmpty ? null : key;
      connectionChecked = false;
    } else {
      final old = cloudServices[service]!;
      cloudServices[service] = CloudService(
        old.id,
        old.label,
        normalized,
        old.model,
        old.models,
      );
      if (key.isEmpty)
        _serviceSecrets.remove(service);
      else
        _serviceSecrets[service] = {'key': key, 'endpoint': normalized};
    }
    await _writeSecrets();
    await _saveSettings();
  }
}
