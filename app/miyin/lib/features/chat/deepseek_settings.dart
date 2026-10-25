import 'package:flutter/material.dart';

import 'chat_host.dart';
import 'deepseek_client.dart';

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
  late List<String> _models;
  late String _model;
  late bool _network, _context, _history;
  String _notice = '';
  bool _busy = false;
  String? _checkedKey;
  List<String>? _checkedModels;

  @override
  void initState() {
    super.initState();
    _models = {...ChatHost.presetModels, ...widget.host.models}.toList();
    _model = widget.host.model ?? _models.first;
    _network = widget.host.allowNetwork;
    _context = widget.host.sendHistory;
    _history = widget.host.saveLocalHistory;
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
    final list = key.isEmpty
        ? await widget.host.checkSavedKey()
        : await widget.host.checkKey(key);
    if (!mounted) return;
    setState(() {
      _models = list;
      if (!list.contains(_model)) {
        _model = list.first;
      }
      _checkedKey = key.isEmpty ? null : key;
      _checkedModels = list;
      _notice = '连接成功，模型列表已更新。保存后生效。';
    });
  });

  Future<void> _save() => _perform(() async {
    if (widget.page == 'privacy') {
      await widget.host.savePrivacy({
        'allowNetwork': _network,
        'sendHistory': _context,
        'saveLocalHistory': _history,
      });
    } else {
      final selected = _custom.text.trim().isNotEmpty
          ? _custom.text.trim()
          : _model;
      if (_key.text.trim().isNotEmpty) {
        if (_checkedKey != _key.text.trim() || _checkedModels == null) {
          throw const ChatFailure('unchecked', '请先检查连接；也可以清空密钥，仅保存模型配置。');
        }
        await widget.host.saveConfiguration(
          _checkedKey!,
          selected,
          _checkedModels!,
        );
      } else {
        await widget.host.saveDraft(selected);
      }
    }
    if (mounted) {
      Navigator.of(context).pop(true);
    }
  });

  Widget _modelPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('DeepSeek\n可以先选择模型并保存，不需要 API Key。预设模型尚未用你的账户验证。'),
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
        widget.host.status['configured'] == true
            ? '密钥已保存，实际发送受 AI 隐私设置控制。'
            : '尚未填写密钥；配置可以保存，暂时不能发起真实对话。',
      ),
    ],
  );

  Widget _providerPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('DeepSeek · 官方服务\nhttps://api.deepseek.com'),
      const SizedBox(height: 16),
      Text(
        widget.host.status['configured'] == true
            ? '已保存密钥'
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
          hintText: widget.host.status['configured'] == true
              ? '留空保留已保存的密钥'
              : '本轮无需填写',
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) {
          _checkedKey = null;
          _checkedModels = null;
        },
      ),
      const SizedBox(height: 12),
      OutlinedButton(
        onPressed: _busy ? null : _check,
        child: const Text('检查连接并读取模型'),
      ),
      const SizedBox(height: 8),
      const Text('只有主动检查或发送消息时访问服务。服务费用由你的账户承担，密钥仅在此设备加密保存。'),
      if (widget.host.status['configured'] == true)
        TextButton(
          onPressed: _busy
              ? null
              : () => _perform(() async {
                  await widget.host.clearConfiguration();
                  if (mounted) {
                    setState(() {
                      _notice = '密钥已移除，模型与隐私偏好保留。';
                    });
                  }
                }),
          child: const Text('移除此设备的密钥'),
        ),
    ],
  );

  Widget _privacyPage() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('允许发送至远程 AI'),
        subtitle: const Text('关闭时不发送聊天内容。主动连接检查仍可单独进行。'),
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
      const SizedBox(height: 12),
      const Text('不会自动提交其他会话、翻译记录、录音或录屏。删除本机历史不会删除服务商可能留存的数据。'),
    ],
  );

  @override
  void dispose() {
    _key.clear();
    _key.dispose();
    _custom.dispose();
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
