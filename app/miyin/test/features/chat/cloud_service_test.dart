import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/cloud_service.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';

void main() {
  test('endpoint normalization accepts base and full compatible routes', () {
    expect(
      CloudService.normalizeEndpoint(
        'https://one.example/v1/chat/completions/',
      ),
      'https://one.example/v1',
    );
    expect(
      CloudService.normalizeEndpoint('https://one.example/v1/models'),
      'https://one.example/v1',
    );
    expect(
      CloudService.endpointFor('dashscope', 'https://other.example'),
      'https://dashscope.aliyuncs.com/compatible-mode/v1',
    );
  });
  test('plain text endpoints and embedded credentials cannot be saved', () {
    for (final value in [
      'http://one.example/v1',
      'https://user:password@one.example',
      'https://one.example?key=secret',
      'https://one.example/#key',
      'https://one.example/\n',
    ]) {
      expect(
        () => CloudService.normalizeEndpoint(value),
        throwsA(isA<ChatFailure>()),
      );
    }
  });
}
