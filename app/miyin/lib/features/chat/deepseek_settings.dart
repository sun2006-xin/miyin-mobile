import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_host.dart';
import 'deepseek_client.dart';

/// A native sheet keeps the API key out of HTML, page storage and RPC messages.
class DeepSeekSettings extends StatefulWidget {
  const DeepSeekSettings({super.key, required this.host});
  final ChatHost host;
  @override
  State<DeepSeekSettings> createState() => _DeepSeekSettingsState();
}

class _DeepSeekSettingsState extends State<DeepSeekSettings> {
  final _key = TextEditingController();
  List<String> _models = [];
  String? _model;
  String _notice = '';
  String? _checkedKey;
  bool _busy = false;
  bool _useSaved = false;

  @override
  void initState() {
    super.initState();
    _useSaved = widget.host.status['configured'] == true;
    _models = [...widget.host.models];
    _model = widget.host.model;
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _notice = '正在检查连接…';
    });
    final key = _key.text.trim();
    final saved = _useSaved && key.isEmpty;
    try {
      final models = saved
          ? await widget.host.checkSavedKey()
          : await widget.host.checkKey(key);
      if (!mounted) return;
      setState(() {
        _models = models;
        if (!models.contains(_model)) {
          _model = models.contains('deepseek-flash')
              ? 'deepseek-flash'
              : models.first;
        }
        _checkedKey = saved ? null : key;
        _notice = '连接成功，请选择模型并保存。';
      });
    } on ChatFailure catch (error) {
      if (mounted) {
        setState(() {
          _notice = error.message;
          _models = [];
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _notice = '读取配置失败，请重新填写密钥。';
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

  Future<void> _save() async {
    setState(() {
      _busy = true;
    });
    try {
      if (_checkedKey != null && _checkedKey == _key.text.trim()) {
        await widget.host.saveConfiguration(_checkedKey!, _model!, _models);
      } else if (_useSaved && _key.text.trim().isEmpty) {
        await widget.host.selectModel(_model!);
      } else {
        throw const ChatFailure('unchecked', '请先检查连接，再保存配置。');
      }
      if (mounted) Navigator.of(context).pop();
    } on ChatFailure catch (error) {
      if (mounted) {
        setState(() {
          _notice = error.message;
        });
      }
    } on PlatformException {
      if (mounted) {
        setState(() {
          _notice = '配置未能保存，请重试。';
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

  @override
  void dispose() {
    _key.clear();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('DeepSeek 模型设置'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('使用你的 DeepSeek 账户。发送的消息会交给 DeepSeek 处理，费用由该账户承担。'),
              const SizedBox(height: 16),
              TextField(
                controller: _key,
                obscureText: true,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: _useSaved ? '已保存；留空继续使用' : '粘贴 DeepSeek API Key',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {
                  _checkedKey = null;
                }),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : _check,
                child: Text(_busy ? '处理中…' : '检查连接并获取模型'),
              ),
              if (_models.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: _model,
                  key: ValueKey(_models.join(',')),
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '默认模型'),
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
                          _model = value;
                        }),
                ),
              if (_notice.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_notice),
                ),
              if (_useSaved)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() {
                            _busy = true;
                          });
                          try {
                            await widget.host.clearConfiguration();
                            if (context.mounted) Navigator.of(context).pop();
                          } catch (_) {
                            if (mounted) {
                              setState(() {
                                _notice = '移除失败，请重试。';
                              });
                            }
                          } finally {
                            if (mounted) {
                              setState(() {
                                _busy = false;
                              });
                            }
                          }
                        },
                  child: const Text('移除此设备的服务配置'),
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
          onPressed: _busy || _model == null ? null : _save,
          child: const Text('保存'),
        ),
      ],
    ),
  );
}
