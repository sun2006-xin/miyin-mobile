import 'deepseek_client.dart';

/// Public configuration only. Credentials belong in the native secret store.
final class CloudService {
  const CloudService(
    this.id,
    this.label,
    this.endpoint,
    this.model,
    this.models, {
    this.checked = false,
  });
  final String id, label, endpoint, model;
  final List<String> models;
  final bool checked;
  static const defaults = <String, CloudService>{
    'openai': CloudService(
      'openai',
      'OpenAI',
      'https://api.openai.com/v1',
      '',
      [],
    ),
    'anthropic': CloudService(
      'anthropic',
      'Claude',
      'https://api.anthropic.com/v1',
      '',
      [],
    ),
    'glm': CloudService(
      'glm',
      'GLM · 智谱',
      'https://open.bigmodel.cn/api/paas/v4',
      '',
      [],
    ),
    'dashscope': CloudService(
      'dashscope',
      '通义千问 · 北京地域',
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
      '',
      [],
    ),
    'siliconflow': CloudService(
      'siliconflow',
      '硅基流动',
      'https://api.siliconflow.cn/v1',
      '',
      [],
    ),
    'custom': CloudService('custom', '自定义兼容服务', '', '', []),
  };
  static String normalizeEndpoint(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        raw.length > 2048 ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(r'[\x00-\x20\\]').hasMatch(raw)) {
      throw const ChatFailure('invalid_endpoint', '请填写不含密钥、参数或片段的 HTTPS 服务地址。');
    }
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    for (final suffix in ['/chat/completions', '/models']) {
      if (path.endsWith(suffix))
        path = path.substring(0, path.length - suffix.length);
    }
    return uri.replace(path: path).toString();
  }

  static String endpointFor(String id, String input) {
    if (id == 'deepseek') return 'https://api.deepseek.com';
    final preset = defaults[id];
    if (preset == null)
      throw const ChatFailure('invalid_provider', '请选择支持的模型服务。');
    return normalizeEndpoint(id == 'custom' ? input : preset.endpoint);
  }

  Map<String, Object?> toJson() => {
    'endpoint': endpoint,
    'model': model,
    'models': models,
    'checked': checked,
  };
  static CloudService? restore(String id, Object? raw) {
    final preset = defaults[id];
    if (preset == null || raw is! Map) return null;
    try {
      final endpoint = id == 'custom' && raw['endpoint'] == ''
          ? ''
          : endpointFor(id, raw['endpoint'] as String);
      final model = raw['model'] as String;
      final models = (raw['models'] as List).cast<String>();
      if (model.length > 128 ||
          models.length > 2000 ||
          models.any((m) => m.length > 128))
        return null;
      return CloudService(
        id,
        preset.label,
        endpoint,
        model,
        models,
        checked: raw['checked'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
