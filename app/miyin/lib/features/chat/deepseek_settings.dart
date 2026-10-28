import 'package:flutter/material.dart';

import 'chat_host.dart';
import 'deepseek_client.dart';
import 'cloud_service.dart';

/// Focused settings pages; API credentials are optional until actual use.
class DeepSeekSettings extends StatefulWidget {
  const DeepSeekSettings({super.key, required this.host, this.page = 'models'});
  final ChatHost host;
  final String page;
  @override
  State<DeepSeekSettings> createState() => _DeepSeekSettingsState();
}

class _DeepSeekSettingsState extends State<DeepSeekSettings> {
  final _key = TextEditingController();
  final _custom = TextEditingController();
  final _endpoint = TextEditingController();
  String? _checkedSignature;
  String get _signature =>
      '$_provider|${['phone', 'ollama'].contains(_provider) ? '' : CloudService.endpointFor(_provider, _endpoint.text)}|${_key.text.trim()}';
  bool get _hasKey => widget.host.keyFor(_provider) != null;
  bool get _savedChecked => _provider == 'deepseek'
      ? widget.host.connectionChecked
      : widget.host.cloudServices[_provider]?.checked == true;
  late List<String> _models;
  late String _model;
  late bool _network, _context, _history;
  late bool _memory;
  late int _contextWindow;
  String _notice = '';
  bool _busy = false;
  late String _provider;
  late bool _thinking;

  @override
  void initState() {
    super.initState();
    _provider = widget.host.provider;
    _thinking = widget.host.thinking;
    _models = List<String>.from(widget.host.status['models'] as List);
    _model = widget.host.modelFor(_provider);
    if (!['phone', 'ollama'].contains(_provider))
      _endpoint.text = widget.host.endpointFor(_provider);
    _network = widget.host.allowNetwork;
    _context = widget.host.sendHistory;
    _history = widget.host.saveLocalHistory;
    _memory = widget.host.useMemory;
    _contextWindow = widget.host.localContextWindow;
  }

  Future<void> _perform(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _notice = '';
    });
    try {
      await action();
    } on ChatFailure catch (error) {
      if (mounted) {
        setState(() {
          _notice = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _notice = '操作未完成，请重试。';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _check() => _perform(() async {
    final key = _key.text.trim();
    final list = _provider == 'phone'
        ? widget.host.modelsFor('phone')
        : _provider == 'ollama'
        ? await widget.host.checkLocalModels()
        : await widget.host.checkCloudModels(_provider, _endpoint.text, key);
    if (!mounted) return;
    setState(() {
      _models = list;
      if (!list.contains(_model)) {
        _model = list.first;
      }
      _checkedSignature = _signature;
      _notice = '连接成功，模型列表已更新。保存后生效。';
    });
  });

  Future<void> _save() => _perform(() async {
    if (widget.page == 'privacy') {
      await widget.host.savePrivacy({
        'allowNetwork': _network,
        'sendHistory': _context,
        'saveLocalHistory': _history,
        'useMemory': _memory,
      });
    } else {
      final selected = _custom.text.trim().isNotEmpty
          ? _custom.text.trim()
          : _model;
      if (['phone', 'ollama'].contains(_provider)) {
        await widget.host.saveService(
          _provider,
          selected,
          deepThinking: _thinking,
          contextWindow: _contextWindow,
          available: _models,
        );
      } else {
        await widget.host.saveCloudService(
          _provider,
          _endpoint.text,
          selected,
          typedKey: _key.text,
          available: _models,
          checked: _checkedSignature == _signature,
        );
      }
    }
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  });

  Widget _modelPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _servicePicker(),
      Text(
        _provider == 'ollama'
            ? '电脑本地模型 · 通过 USB 调用，不是手机离线运行。'
            : '选择模型或手动填写模型 ID；服务密钥可在“模型服务配置”中填写。',
      ),
      if (_provider == 'ollama') ...[
        DropdownButtonFormField<int>(
          initialValue: _contextWindow,
          decoration: const InputDecoration(
            labelText: '保留最近原文的长度',
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 8192, child: Text('标准 · 8K')),
            DropdownMenuItem(value: 16384, child: Text('较长 · 16K')),
            DropdownMenuItem(value: 32768, child: Text('长对话 · 32K')),
          ],
          onChanged: _busy
              ? null
              : (value) => setState(() => _contextWindow = value ?? 8192),
        ),
        const Text('更长的原文需要更多电脑内存，也可能更慢。接近上限后可自动整理会话摘要。'),
        OutlinedButton(
          onPressed: _busy ? null : _check,
          child: const Text('连接电脑并读取模型'),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('深度思考'),
          subtitle: const Text('需模型支持，可能等待更久；可以随时停止。'),
          value: _thinking,
          onChanged: _busy ? null : (v) => setState(() => _thinking = v),
        ),
      ],
      if (_models.isEmpty) const Text('尚未读取模型。可在服务配置中读取，或在下方填写模型 ID。'),
      RadioGroup<String>(
        groupValue: _model,
        onChanged: (value) {
          if (!_busy && value != null) {
            setState(() {
              _model = value;
              _custom.clear();
            });
          }
        },
        child: Column(
          children: _models
              .map(
                (id) => RadioListTile<String>(
                  value: id,
                  title: Text(id),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  subtitle: Text(
                    id == 'deepseek-flash'
                        ? '日常文字对话'
                        : id == 'deepseek-v4-pro'
                        ? '复杂任务'
                        : '自定义模型',
                  ),
                ),
              )
              .toList(),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _custom,
        enabled: !_busy,
        autocorrect: false,
        decoration: const InputDecoration(
          labelText: '其他模型 ID（选填）',
          hintText: '服务新增模型时可手动填写',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      Text(
        _provider == 'ollama'
            ? '无需 API Key；请保持 USB 调试连接和电脑 Ollama 运行。实际发送受 AI 隐私设置控制。'
            : _hasKey
            ? '密钥已保存，实际发送受 AI 隐私设置控制。'
            : '尚未填写密钥；配置可以保存，暂时不能发起真实对话。',
      ),
    ],
  );

  Widget _servicePicker() => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: DropdownButtonFormField<String>(
      initialValue: _provider,
      decoration: const InputDecoration(
        labelText: '模型服务',
        border: OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: 'phone', child: Text('手机内置模型')),
        DropdownMenuItem(value: 'deepseek', child: Text('DeepSeek · 云端服务')),
        DropdownMenuItem(value: 'ollama', child: Text('电脑本地模型 · Ollama')),
        for (final entry in CloudService.defaults.entries)
          DropdownMenuItem(value: entry.key, child: Text(entry.value.label)),
      ],
      onChanged: _busy
          ? null
          : (value) => setState(() {
              if (value == null) return;
              _provider = value;
              _models = [...widget.host.modelsFor(value)];
              _model = widget.host.modelFor(value);
              if (!['phone', 'ollama'].contains(value))
                _endpoint.text = widget.host.endpointFor(value);
              _custom.clear();
              _key.clear();
              _checkedSignature = null;
              _notice = '';
            }),
    ),
  );

  Widget _providerPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _servicePicker(),
      if (_provider == 'phone') ...[
        const Text('手机内置模型在本机运行，无需服务地址或密钥。'),
      ] else if (_provider == 'ollama') ...[
        const Text(
          '电脑本地模型 · Ollama\nUSB 接口：http://127.0.0.1:11435\n无需密钥。连接电脑并读取模型后，在“选择 AI 模型”中选择。',
        ),
        OutlinedButton(
          onPressed: _busy ? null : _check,
          child: const Text('连接电脑并读取模型'),
        ),
      ] else ...[
        if (_provider == 'custom')
          TextField(
            controller: _endpoint,
            enabled: !_busy,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '服务基础地址',
              hintText: 'https://服务地址/v1',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _checkedSignature = null),
          )
        else
          SelectableText(CloudService.endpointFor(_provider, '')),
        const SizedBox(height: 8),
        const Text('使用兼容的文字聊天接口。每家服务分别保存；自定义地址更换后，旧密钥不会带到新地址。'),
        const SizedBox(height: 16),
        Text(
          _hasKey
              ? (_savedChecked ? '已保存密钥 · 曾读取模型列表' : '已保存密钥 · 待验证')
              : '未填写密钥 · 可以先完成模型和隐私设置',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _key,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'API Key（可稍后填写）',
            hintText: _hasKey ? '地址不变时，留空保留已保存的密钥' : '可先保存模型，稍后填写',
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) {
            _checkedSignature = null;
          },
        ),
        const SizedBox(height: 12),
        if (_models.isNotEmpty)
          DropdownButtonFormField<String>(
            key: ValueKey('$_provider-$_model'),
            initialValue: _models.contains(_model) ? _model : null,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '使用的模型',
              border: OutlineInputBorder(),
            ),
            items: _models
                .map(
                  (id) => DropdownMenuItem(
                    value: id,
                    child: Text(id, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    if (value != null) _model = value;
                    _custom.clear();
                  }),
          ),
        const SizedBox(height: 12),
        TextField(
          controller: _custom,
          enabled: !_busy,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: '模型 ID',
            hintText: _model.isEmpty ? '从服务读取或手动填写' : _model,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _busy ? null : _check,
          child: const Text('检查连接并读取模型'),
        ),
        const SizedBox(height: 8),
        const Text('保存不发起聊天；未检查的配置会保留为待验证。主动检查只读取模型列表。密钥仅在此设备加密保存。'),
        if (_hasKey)
          TextButton(
            onPressed: _busy
                ? null
                : () => _perform(() async {
                    await widget.host.clearConfiguration(service: _provider);
                    if (mounted) {
                      setState(() {
                        _notice = '密钥已移除，模型与隐私偏好保留。';
                      });
                    }
                  }),
            child: const Text('移除此设备的密钥'),
          ),
      ],
    ],
  );

  Widget _privacyPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('允许发送至所选模型服务'),
        subtitle: const Text('包括电脑本地模型和云端服务。关闭时不发送聊天；主动检查连接可单独进行。'),
        value: _network,
        onChanged: _busy
            ? null
            : (v) => setState(() {
                _network = v;
              }),
      ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('携带当前对话上下文'),
        subtitle: const Text('关闭后只发送当前消息，不提交此前的聊天。'),
        value: _context,
        onChanged: _busy
            ? null
            : (v) => setState(() {
                _context = v;
              }),
      ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('保存会话历史'),
        subtitle: const Text('只保存在本机。关闭后新消息临时保留，已有记录不删除。'),
        value: _history,
        onChanged: _busy
            ? null
            : (v) => setState(() {
                _history = v;
              }),
      ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('自动整理会话记忆'),
        subtitle: const Text('当前用于电脑本地模型。较早对话整理成摘要，最近原文保留；只在当前会话使用。'),
        value: _memory,
        onChanged: _busy ? null : (v) => setState(() => _memory = v),
      ),
      const SizedBox(height: 12),
      const Text('不会自动提交其他会话、翻译记录、录音或录屏。删除本机历史不会删除服务商可能留存的数据。'),
    ],
  );

  @override
  void dispose() {
    _key.clear();
    _key.dispose();
    _custom.dispose();
    _endpoint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.page) {
      'provider' => '模型服务配置',
      'privacy' => 'AI 隐私设置',
      _ => '选择 AI 模型',
    };
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                switch (widget.page) {
                  'provider' => _providerPage(),
                  'privacy' => _privacyPage(),
                  _ => _modelPage(),
                },
                if (_notice.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_notice),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? '处理中…' : '保存'),
          ),
        ],
      ),
    );
  }
}
