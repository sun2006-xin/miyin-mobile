import 'package:flutter/material.dart';

import 'chat_host.dart';
import 'deepseek_client.dart';

/// Only the credential field remains native. No key crosses the WebView bridge.
class ServiceKeySheet extends StatefulWidget {
  const ServiceKeySheet({
    super.key,
    required this.host,
    required this.service,
    required this.endpoint,
    required this.colors,
  }) : onSave = null, hasCredential = false, isVoice = false;
  const ServiceKeySheet.voice({
    super.key,
    required this.endpoint,
    required this.colors,
    required this.onSave,
    required this.hasCredential,
  }) : host = null, service = 'qwen-tts', isVoice = true;
  final ChatHost? host;
  final Future<void> Function(String)? onSave;
  final bool hasCredential, isVoice;
  final String service, endpoint;
  final Map<String, Object?> colors;
  @override
  State<ServiceKeySheet> createState() => _ServiceKeySheetState();
}

class _ServiceKeySheetState extends State<ServiceKeySheet> {
  final keyText = TextEditingController();
  bool busy = false;
  String error = '';
  Color color(String name, Color fallback) {
    final raw = widget.colors[name];
    if (raw is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(raw))
      return Color(0xff000000 | int.parse(raw.substring(1), radix: 16));
    return fallback;
  }

  Future<void> save({bool remove = false}) async {
    if (!remove && keyText.text.trim().isEmpty) {
      setState(() => error = '请填写新的密钥，或点击返回保留已有密钥。');
      return;
    }
    setState(() => busy = true);
    try {
      final value = remove ? '' : keyText.text.trim();
      if (widget.onSave != null) {
        await widget.onSave!(value);
      } else {
        await widget.host!.saveCredential(widget.service, widget.endpoint, value);
      }
      if (mounted) Navigator.pop(context, true);
    } on ChatFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '密钥未能保存，请重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    keyText.clear();
    keyText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = color('accent', const Color(0xff137f84)),
        ink = color('ink', const Color(0xff20454a)),
        panel = color('panel', const Color(0xfff6fbfa));
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: accent.withValues(alpha: .25)),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: .12),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Theme(
            data: Theme.of(context).copyWith(
              colorScheme: ColorScheme.fromSeed(
                seedColor: accent,
                surface: panel,
                onSurface: ink,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.isVoice ? '语音服务密钥' : '服务密钥',
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w600,
                    color: ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.endpoint,
                  style: TextStyle(
                    fontSize: 12,
                    color: ink.withValues(alpha: .7),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: keyText,
                  enabled: !busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: '仅在这台设备加密保存',
                    filled: true,
                    fillColor: accent.withValues(alpha: .04),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(error, style: TextStyle(color: ink)),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => Navigator.pop(context, false),
                      child: const Text('返回'),
                    ),
                    if (widget.hasCredential || widget.host?.keyFor(widget.service) != null)
                      TextButton(
                        onPressed: busy ? null : () => save(remove: true),
                        child: const Text('移除密钥'),
                      ),
                    FilledButton(
                      onPressed: busy ? null : () => save(),
                      child: Text(busy ? '正在保存…' : '保存密钥'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
