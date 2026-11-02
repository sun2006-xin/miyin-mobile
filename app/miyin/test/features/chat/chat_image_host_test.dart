import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miyin_app/features/chat/chat_host.dart';
import 'package:miyin_app/features/chat/chat_image.dart';
import 'package:miyin_app/features/chat/chat_image_request.dart';
import 'package:miyin_app/features/chat/chat_image_store.dart';
import 'package:miyin_app/features/chat/deepseek_client.dart';
import 'package:miyin_app/features/chat/phone_llm_client.dart';
import 'package:miyin_app/features/miyin/attachment_source_picker.dart';
import 'package:miyin_app/features/miyin/translation_attachment_ocr.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Host image tests must not open an HTTP client');
  }
}

class _Picker implements TranslationImageSourcePicker {
  _Picker(this.selected);
  PickedTranslationImage? selected;
  final kinds = <AttachmentSourceKind>[];
  final disposed = <PickedTranslationImage>[];
  @override
  Future<PickedTranslationImage?> pickTranslationImage(
    AttachmentSourceKind kind,
  ) async {
    kinds.add(kind);
    return selected;
  }

  @override
  Future<void> disposeTranslationImage(PickedTranslationImage image) async {
    disposed.add(image);
  }
}

class _Recognizer implements TranslationImageTextRecognizer {
  final paths = <String>[];
  @override
  Future<TranslationImageRecognition> recognize(String localPath) async {
    paths.add(localPath);
    return const TranslationImageRecognition(
      recognizedText: '  explicit fixture text  ',
      previewDataUrl: 'data:image/jpeg;base64,not-returned',
      width: 300,
      height: 200,
      blocks: [],
    );
  }
}

class _TextClient implements ChatClient {
  int calls = 0;
  @override
  void cancel() {}
  @override
  Stream<String> complete(
    String model,
    List<Map<String, String>> messages,
  ) async* {
    calls++;
    yield 'fixture';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Uint8List png;
  late Directory temporary, private;
  late File original;
  late ChatImageStore store;
  late ChatHost host;
  late _Picker picker;
  late _Recognizer recognizer;
  late _NoNetwork noNetwork;
  HttpOverrides? previousOverrides;
  var hostClosed = false;
  final events = <Map<String, Object?>>[];
  final nativeMethods = <String>[];
  const secrets = MethodChannel('com.miyin.app/chat-secrets');

  setUpAll(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xff1177aa), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(300, 200);
    png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();
    image.dispose();
    picture.dispose();
  });

  ChatHost open() => ChatHost(
    onEvent: (event) async {
      events.add(event);
    },
    databasePath: '${temporary.path}/chat.db',
    databaseFactory: databaseFactoryFfi,
    imageStore: store,
    imagePicker: picker,
    imageTextRecognizer: recognizer,
  );

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('chat-image-host-');
    private = Directory('${temporary.path}/private');
    original = await File('${temporary.path}/selected.png').writeAsBytes(png);
    store = ChatImageStore(directory: private);
    picker = _Picker(
      PickedTranslationImage(
        path: original.path,
        name: r'C:\private-name\selected.png',
        mimeType: 'image/jpeg',
      ),
    );
    recognizer = _Recognizer();
    events.clear();
    nativeMethods.clear();
    hostClosed = false;
    previousOverrides = HttpOverrides.current;
    noNetwork = _NoNetwork();
    HttpOverrides.global = noNetwork;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secrets, (_) async => null);
    messenger.setMockMethodCallHandler(PhoneLlmClient.channel, (call) async {
      nativeMethods.add(call.method);
      throw StateError('Unexpected phone model operation');
    });
    host = open()..provider = 'phone';
  });

  tearDown(() async {
    if (!hostClosed) await host.close();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secrets, null);
    messenger.setMockMethodCallHandler(PhoneLlmClient.channel, null);
    HttpOverrides.global = previousOverrides;
    await temporary.delete(recursive: true);
  });

  Matcher failure(String code) =>
      isA<ChatFailure>().having((error) => error.code, 'code', code);
  Map<String, Object?> request(List<Map<String, Object?>> messages) => {
    'requestId': 'fixture-request',
    'messages': messages,
  };
  Future<Map<String, Object?>> pick([String kind = 'image']) =>
      host.handle('chat.image.pick', {'kind': kind});
  Map<String, Object?> history(String id) => {
    'id': 'fixture-conversation',
    'messages': [
      {
        'id': 'user-image',
        'role': 'user',
        'status': 'complete',
        'text': 'fixture',
        'attachments': [
          {
            'kind': 'image',
            'imageId': id,
            'name': 'selected.png',
            'mimeType': 'image/png',
            'bytes': png.length,
          },
        ],
      },
    ],
  };

  test('phone original-image request explicitly fails without OCR or model preparation', () async {
    expect(
      () => host.start(
        request([
          {
            'role': 'user',
            'content': 'look',
            'imageIds': ['a' * 32],
          },
        ]),
      ),
      throwsA(failure('image_unsupported')),
    );
    expect(recognizer.paths, isEmpty);
    expect(nativeMethods, isEmpty);
    expect(noNetwork.attempts, 0);
    expect(await private.exists(), isFalse);
  });

  test(
    'network consent rejects before malformed image IDs or local store access',
    () async {
      host.provider = 'ollama';
      expect(
        () => host.start(
          request([
            {
              'role': 'user',
              'content': 'look',
              'imageIds': ['../../source.png'],
            },
          ]),
        ),
        throwsA(failure('network_disabled')),
      );
      expect(recognizer.paths, isEmpty);
      expect(noNetwork.attempts, 0);
      expect(await private.exists(), isFalse);
    },
  );

  test('malformed image IDs and assistant image bindings are rejected', () {
    for (final ids in <Object>[
      ['../selected.png'],
      ['A' * 32],
      [7],
      'a' * 32,
      List.filled(5, 'a' * 32),
    ]) {
      expect(
        () => host.start(
          request([
            {'role': 'user', 'content': 'look', 'imageIds': ids},
          ]),
        ),
        throwsA(failure('invalid_image')),
      );
    }
    expect(
      () => host.start(
        request([
          {
            'role': 'assistant',
            'content': 'old',
            'imageIds': ['a' * 32],
          },
          {'role': 'user', 'content': 'new'},
        ]),
      ),
      throwsA(failure('invalid_image')),
    );
    expect(nativeMethods, isEmpty);
    expect(noNetwork.attempts, 0);
  });

  test(
    'sendHistory off drops old image refs and late phone readiness cannot send',
    () async {
      host.sendHistory = false;
      final preparing = Completer<void>();
      final ready = Completer<Map<String, Object?>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PhoneLlmClient.channel, (call) async {
            nativeMethods.add(call.method);
            if (call.method == 'prepare') {
              preparing.complete();
              return ready.future;
            }
            return null;
          });
      final result = host.start(
        request([
          {
            'role': 'user',
            'content': 'old picture',
            'imageIds': ['b' * 32],
          },
          {'role': 'assistant', 'content': 'old answer'},
          {'role': 'user', 'content': 'current text'},
        ]),
      );
      expect(result['status'], 'started');
      await preparing.future.timeout(const Duration(seconds: 3));
      host.cancel();
      ready.complete({
        'endpoint': 'http://127.0.0.1:11438/v1',
        'key': 'fixture-only',
        'contextTokens': 4096,
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(nativeMethods, ['prepare']);
      expect(recognizer.paths, isEmpty);
      expect(noNetwork.attempts, 0);
      expect(events.where((event) => event['type'] == 'delta'), isEmpty);
      expect(await private.exists(), isFalse);
    },
  );

  test(
    'picker stores original bytes; metadata is safe; OCR is explicit only',
    () async {
      final metadata = await pick('camera');
      final id = metadata['id']! as String;
      expect(id, matches(RegExp(r'^[a-f0-9]{32}$')));
      expect(
        metadata.keys,
        unorderedEquals([
          'id',
          'name',
          'mimeType',
          'bytes',
          'thumbnailDataUrl',
        ]),
      );
      expect(metadata['name'], 'selected.png');
      expect(metadata['mimeType'], 'image/png');
      expect(picker.kinds, [AttachmentSourceKind.camera]);
      expect(picker.disposed, hasLength(1));
      expect((await store.readImage(id)).bytes, png);
      expect(await original.readAsBytes(), png);
      final encoded = jsonEncode(metadata);
      expect(encoded, isNot(contains(temporary.path)));
      expect(encoded, isNot(contains(base64Encode(png))));
      expect(recognizer.paths, isEmpty);
      final preview = await host.handle('chat.image.preview', {'imageId': id});
      expect(preview.keys, unorderedEquals(['imageId', 'dataUrl']));
      expect(
        base64Decode((preview['dataUrl']! as String).split(',').last),
        png,
      );
      expect(recognizer.paths, isEmpty);
      final extracted = await host.handle('chat.image.extract', {
        'imageId': id,
      });
      expect(extracted, {'text': 'explicit fixture text'});
      expect(recognizer.paths, [await store.verifiedPath(id)]);
      expect(jsonEncode(extracted), isNot(contains(temporary.path)));
      expect(noNetwork.attempts, 0);
    },
  );

  test(
    'image actions reject paths and unknown preview IDs without invoking OCR',
    () async {
      for (final method in [
        'chat.image.preview',
        'chat.image.extract',
        'chat.image.discard',
      ]) {
        await expectLater(
          host.handle(method, {'imageId': original.path}),
          throwsA(failure('invalid_image')),
        );
      }
      await expectLater(
        host.handle('chat.image.preview', {'imageId': 'f' * 32}),
        throwsA(failure('image_missing')),
      );
      await expectLater(pick('document'), throwsA(failure('invalid_image')));
      expect(picker.kinds, isEmpty);
      expect(recognizer.paths, isEmpty);
      expect(noNetwork.attempts, 0);
    },
  );

  test(
    'history cleanup waits for an image import and pending registration',
    () async {
      await host.close();
      final entered = Completer<void>();
      final release = Completer<void>();
      store = ChatImageStore(
        directory: private,
        thumbnailRenderer: (_) async {
          entered.complete();
          await release.future;
          return png;
        },
      );
      host = open();
      final selecting = pick();
      await entered.future;
      var saved = false;
      final saving = host.saveHistory([]).then((_) {
        saved = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(saved, isFalse);
      release.complete();
      final id = (await selecting)['id']! as String;
      await saving;
      expect((await store.readImage(id)).bytes, png);
      expect(noNetwork.attempts, 0);
    },
  );

  test('history deletion removes saved originals and retains unrelated pending selection', () async {
    final savedId = (await pick())['id']! as String;
    final pendingId = (await pick())['id']! as String;
    await host.handle('chat.history.save', {
      'conversations': [history(savedId)],
    });
    final rows = await host.loadHistory([]);
    expect(rows, [history(savedId)]);
    expect(jsonEncode(rows), isNot(contains(temporary.path)));
    expect(jsonEncode(rows), isNot(contains(base64Encode(png))));
    await host.handle('chat.image.discard', {'imageId': savedId});
    expect((await store.readImage(savedId)).bytes, png);
    await host.handle('chat.history.save', {'conversations': []});
    await expectLater(
      store.readImage(savedId),
      throwsA(isA<FileSystemException>()),
    );
    expect((await store.readImage(pendingId)).bytes, png);
    await host.handle('chat.image.discard', {'imageId': pendingId});
    await expectLater(
      store.readImage(pendingId),
      throwsA(isA<FileSystemException>()),
    );
    expect(await original.readAsBytes(), png);
  });

  test('reopened history keeps saved images and closes away unsaved pending images', () async {
    final savedId = (await pick())['id']! as String;
    final pendingId = (await pick())['id']! as String;
    await host.saveHistory([history(savedId)]);
    hostClosed = true;
    await host.close();
    await expectLater(
      store.readImage(pendingId),
      throwsA(isA<FileSystemException>()),
    );
    expect((await store.readImage(savedId)).bytes, png);
    store = ChatImageStore(directory: private);
    host = open()..provider = 'phone';
    hostClosed = false;
    expect(await host.loadHistory([]), [history(savedId)]);
    final preview = await host.handle('chat.image.preview', {
      'imageId': savedId,
    });
    expect(base64Decode((preview['dataUrl']! as String).split(',').last), png);
    await host.saveHistory([]);
    await expectLater(
      store.readImage(savedId),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'cancel while private images load never creates a provider request',
    () async {
      final loading = Completer<Map<int, List<ChatImage>>>();
      final entered = Completer<void>();
      var creates = 0;
      final client = _TextClient();
      final request = ChatImageRequest(
        load: () {
          entered.complete();
          return loading.future;
        },
        create: (_) {
          creates++;
          return client;
        },
      );
      final done = expectLater(
        request.complete('fixture', [
          {'role': 'user', 'content': 'look'},
        ]).join(),
        throwsA(failure('canceled')),
      );
      await entered.future;
      request.cancel();
      loading.complete({
        0: [ChatImage(mimeType: 'image/png', bytes: png)],
      });
      await done;
      expect(creates, 0);
      expect(client.calls, 0);
      expect(noNetwork.attempts, 0);
    },
  );
}
