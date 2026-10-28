import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/adaptive_refresh_coordinator.dart';
import '../../core/storage/translation_history_repository.dart';
import '../../core/translation/mlkit_translation_engine.dart';
import '../../core/translation/translation_service.dart';
import '../chat/chat_host.dart';
import '../chat/deepseek_client.dart';
import '../chat/deepseek_settings.dart';
import '../chat/service_key_sheet.dart';
import '../chat/cloud_service.dart';
import 'attachment_source_picker.dart';
import 'avatar_image_picker.dart';
import 'live_audio_archive.dart';
import 'live_session_microphone_recorder.dart';
import 'multilingual_asr_model_store.dart';
import 'offline_speech_recognizer.dart';
import 'offline_speech_synthesizer.dart';
import 'translation_rpc_router.dart';

/// Mobile host for the approved V5 preview.
///
/// The preview is bundled locally so the phone UI keeps the exact same screen
/// layout, CSS, mode wheel, orb appearance controls, and interactions while
/// remaining available without a network connection.
class MiyinMobileApp extends StatefulWidget {
  const MiyinMobileApp({super.key});

  @override
  State<MiyinMobileApp> createState() => _MiyinMobileAppState();
}

class _MiyinMobileAppState extends State<MiyinMobileApp>
    with WidgetsBindingObserver {
  static const _floatingChannel = MethodChannel('com.miyin.app/floating');
  static const _playbackChannel = MethodChannel(
    'com.miyin.app/playback-capture',
  );
  static const _subtitleChannel = MethodChannel(
    'com.miyin.app/subtitle-overlay',
  );
  static const _microphoneSessionChannel = MethodChannel(
    'com.miyin.app/microphone-session',
  );
  static const _attachmentOcrChannel = MethodChannel(
    'com.miyin.app/attachment-ocr',
  );
  late final WebViewController _controller;
  late final ChatHost _chat;
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _chatSettingsOpen = false;
  late final AdaptiveRefreshCoordinator _refreshCoordinator;
  late final PlatformAttachmentSourcePicker _attachmentSourcePicker;
  late final PlatformAvatarImagePicker _avatarImagePicker;
  late final Future<PickedAttachmentSource?> _recoveredAttachment;
  StreamSubscription<Object?>? _voiceEvents;
  StreamSubscription<Map<String, Object?>>? _offlineVoiceEvents;
  StreamSubscription<Map<String, Object?>>? _multilingualModelEvents;
  StreamSubscription<Object?>? _playbackEvents;
  Future<void> _playbackRecognitionQueue = Future<void>.value();
  Future<void> _playbackQueue = Future<void>.value();
  Future<void> _micTranslationQueue = Future<void>.value();
  Future<void>? _micLoopTask;
  Completer<void>? _micLoopWake;
  Completer<void>? _playbackStopped;
  bool _playbackPreviewPrepared = false;
  int _playbackPreviewGeneration = 0;
  String? _playbackCaptureSessionId;
  final List<Map<String, String>> _liveEntries = <Map<String, String>>[];
  final Set<String> _sessionAudioIds = <String>{};
  bool _liveRecordAudio = false;
  String? _liveRecordingSessionId;
  LiveSessionMicrophoneRecorder? _liveMicrophoneRecorder;
  int? _liveMicrophoneStartedAtMs;
  Map<String, Object?>? _lastLiveRecording;
  String? _liveRecordingError;
  String _liveSourceTag = 'zh-Hans';
  String _liveTargetTag = 'en';
  bool _liveActive = false;
  String? _liveMode;
  bool _liveStopping = false;
  String? _micSessionId;
  int _micGeneration = 0;
  bool _livePendingEnd = false;
  int _latestOverlayCapturedAtMs = 0;
  final Map<String, String> _livePreviewText = <String, String>{};
  final Map<String, String> _livePreviewSession = <String, String>{};
  final Map<String, Timer> _livePreviewTimers = <String, Timer>{};
  final Map<String, int> _livePreviewBusy = <String, int>{};
  int _livePreviewGeneration = 0;
  bool _appVisible = true;
  var _isLoading = true;
  var _nativeHostReady = false;
  String? _loadError;
  String? _pendingFloatingScreen;
  String? _pendingScreenshotPath;
  Future<TranslationRpcRouter>? _rpcRouter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshCoordinator = AdaptiveRefreshCoordinator(
      requestHighRefresh: _setNativeHighRefresh,
    );
    _attachmentSourcePicker = PlatformAttachmentSourcePicker();
    _avatarImagePicker = PlatformAvatarImagePicker();
    _recoveredAttachment = _attachmentSourcePicker.retrieveLostData();
    unawaited(
      LiveAudioArchive.instance.purgePending().catchError((Object error) {
        debugPrint('Could not remove unfinished conference audio: $error');
      }),
    );
    if (defaultTargetPlatform == TargetPlatform.android) {
      _playbackEvents =
          const EventChannel('com.miyin.app/playback-capture-events')
              .receiveBroadcastStream()
              .listen(_onPlaybackCaptureEvent, onError: _logVoiceEventError);
      _floatingChannel.setMethodCallHandler((call) async {
        if (call.method == 'openScreen' && call.arguments is String) {
          _pendingFloatingScreen = call.arguments as String;
          await _openPendingFloatingScreen();
        } else if (call.method == 'openScreenshot' &&
            call.arguments is String) {
          _pendingScreenshotPath = call.arguments as String;
          await _consumeScreenshot();
        } else if (call.method == 'screenshotError' &&
            call.arguments is String) {
          await _showScreenshotError(call.arguments as String);
        }
      });
      _subtitleChannel.setMethodCallHandler((call) async {
        if (call.method == 'quickPreferencesChanged' && call.arguments is Map) {
          final changed = <String, String>{};
          (call.arguments as Map).forEach((key, value) {
            if (key is String && value is String &&
                (key == 'font' || key == 'color' || key == 'display' || key == 'size')) {
              changed[key] = value;
            }
          });
          await _dispatchSubtitleQuickPreferences(changed);
        }
      });
      _offlineVoiceEvents = MiyinOfflineSpeechRecognizer.instance.events.listen(
        _forwardVoiceEvent,
        onError: _logVoiceEventError,
      );
      _multilingualModelEvents = MiyinMultilingualAsrModelStore.instance.events
          .listen(_forwardVoiceEvent, onError: _logVoiceEventError);
      unawaited(_prepareOfflineVoiceResources());
      _voiceEvents = const EventChannel('com.miyin.app/voice-events')
          .receiveBroadcastStream()
          .listen(_forwardVoiceEvent, onError: _logVoiceEventError);
    }
    _controller = WebViewController();
    _chat = ChatHost(
      onEvent: (event) async {
        if (!_nativeHostReady || !mounted) return;
        final literal = jsonEncode(jsonEncode(event));
        await _controller.runJavaScript(
          'window.dispatchEvent(new CustomEvent("miyin:chat-event",{detail:JSON.parse($literal)}));',
        );
      },
    );
    unawaited(_configureWebView());
  }

  Future<void> _prepareOfflineVoiceResources() async {
    // The bundled TTS archive is large. Unpack it before loading Whisper into
    // its worker isolate to avoid two large startup allocations at once.
    await MiyinOfflineSpeechSynthesizer.instance.prepare();
    await MiyinOfflineSpeechRecognizer.instance.prepare();
  }

  Future<void> _configureWebView() async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.addJavaScriptChannel(
      'MiyinPerformance',
      onMessageReceived: (message) {
        _refreshCoordinator.onActivitySignal(message.message);
      },
    );
    await _controller.addJavaScriptChannel(
      'MiyinApp',
      onMessageReceived: (message) {
        unawaited(_handleNativeRequest(message.message));
      },
    );
    await _controller.addJavaScriptChannel(
      'MiyinNavigation',
      onMessageReceived: (message) {
        if (message.message == 'exit') unawaited(SystemNavigator.pop());
      },
    );
    await _controller.setBackgroundColor(const Color(0xFFFFFFFF));
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          return uri != null &&
                  uri.scheme == 'file' &&
                  uri.path.endsWith('/assets/miyin_v5/index.html')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onPageStarted: (_) {
          _chat.cancel();
          _nativeHostReady = false;
          if (mounted) {
            setState(() {
              _isLoading = true;
              _loadError = null;
            });
          }
        },
        onPageFinished: (_) {
          unawaited(_markNativeHostReady());
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true && mounted) {
            setState(() {
              _isLoading = false;
              _loadError = error.description;
            });
          }
        },
      ),
    );
    await _controller.loadFlutterAsset('assets/miyin_v5/index.html');
  }

  Future<TranslationRpcRouter> _getRpcRouter() =>
      _rpcRouter ??= _createRpcRouter().catchError((Object error) {
        _rpcRouter = null;
        throw error;
      });

  Future<TranslationRpcRouter> _createRpcRouter() async {
    final history = await SqliteTranslationHistoryRepository.open();
    return TranslationRpcRouter(
      TranslationService(engine: MlKitTranslationEngine(), history: history),
      attachmentSourcePicker: _attachmentSourcePicker,
      translationImageSourcePicker: _attachmentSourcePicker,
      translationArticleSourcePicker: _attachmentSourcePicker,
      avatarImagePicker: _avatarImagePicker,
    );
  }

  Future<void> _handleNativeRequest(String rawMessage) async {
    Map<String, Object?> response;
    try {
      final request = jsonDecode(rawMessage);
      if (request is Map &&
          request['method'] is String &&
          (request['method'] as String).startsWith('chat.')) {
        if (request['version'] != 1 ||
            request['id'] is! String ||
            rawMessage.length > 9 * 1024 * 1024) {
          throw const ChatFailure('invalid_request', '聊天请求格式不正确。');
        }
        final method = request['method'] as String;
        Map<String, Object?> result;
        if (method == 'chat.configure') {
          if (_chatSettingsOpen || !mounted) {
            throw const ChatFailure('busy', '模型设置已打开。');
          }
          _chatSettingsOpen = true;
          try {
            try {
              await _chat.loadConfiguration();
            } catch (_) {
              // A restored backup may lack its original Keystore key.
              // Let the user replace it instead of silently dropping it.
            }
            var settingsSaved = false;
            if (mounted) {
              final page = (request['params'] is Map)
                  ? (request['params'] as Map)['page'] : null;
              settingsSaved = await showDialog<bool>(
                context: _navigatorKey.currentContext!,
                barrierDismissible: false,
                builder: (_) {
                  final params = request['params'] is Map ? Map<String,Object?>.from(request['params'] as Map) : <String,Object?>{};
                  if(page == 'key') {
                    final service = params['service'] as String? ?? 'deepseek';
                    final endpoint = CloudService.endpointFor(service,params['endpoint'] as String? ?? '');
                    return ServiceKeySheet(host:_chat,service:service,endpoint:endpoint,colors:params['colors'] is Map ? Map<String,Object?>.from(params['colors'] as Map) : {});
                  }
                  return DeepSeekSettings(host: _chat,page: ['models','provider','privacy'].contains(page) ? page as String : 'models');
                },
              ) == true;
            }
            result = {..._chat.status, 'settingsSaved': settingsSaved};
          } finally {
            _chatSettingsOpen = false;
          }
        } else {
          result = await _chat.handle(
            method,
            request['params'] is Map
                ? Map<String, Object?>.from(request['params'] as Map)
                : {},
          );
        }
        response = {
          'version': 1,
          'id': request['id'],
          'ok': true,
          'result': result,
        };
      } else if (request is Map &&
          request['method'] is String &&
          (request['method'] as String).startsWith('live.')) {
        final result = await _handleLiveRequest(
          request['method'] as String,
          request['params'] is Map
              ? Map<String, Object?>.from(request['params'] as Map)
              : <String, Object?>{},
        );
        response = <String, Object?>{
          'version': 1,
          'id': request['id'],
          'ok': true,
          'result': result,
        };
      } else {
        response = await (await _getRpcRouter()).handle(rawMessage);
      }
    } on ChatFailure catch (error) {
      response = {
        'version': 1,
        'id': _requestIdFrom(rawMessage),
        'ok': false,
        'error': {'code': error.code, 'message': error.message},
      };
    } catch (error) {
      response = {
        'version': 1,
        'id': _requestIdFrom(rawMessage),
        'ok': false,
        'error': {'code': 'native_unavailable', 'message': '本机翻译暂时不可用。'},
      };
      debugPrint('Miyin native request failed (${error.runtimeType}).');
    }
    if (!_nativeHostReady) return;
    try {
      final responseLiteral = jsonEncode(jsonEncode(response));
      await _controller.runJavaScript(
        'window.MiyinNativeBridge?.receive(JSON.parse($responseLiteral));',
      );
    } on PlatformException catch (error) {
      debugPrint(
        'Could not return translation response to WebView: ${error.message}',
      );
    }
  }

  Future<Map<String, Object?>> _handleLiveRequest(
    String method,
    Map<String, Object?> params,
  ) async {
    final overlayPrefs = params['overlay'] is Map
        ? Map<String, String>.from(
            (params['overlay'] as Map).map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ),
          )
        : <String, String>{};
    switch (method) {
      case 'live.playAudio':
        final id = params['audioId'];
        if (id is! String) throw const FormatException('缺少音频编号。');
        return LiveAudioArchive.instance.play(id);
      case 'live.stopAudio':
        await LiveAudioArchive.instance.stop();
        return <String, Object?>{'status': 'stopped'};
      case 'live.deleteAudio':
        final ids = params['audioIds'];
        if (ids is! List) throw const FormatException('缺少音频编号。');
        await LiveAudioArchive.instance.delete(ids.whereType<String>());
        return <String, Object?>{'status': 'deleted'};
      case 'live.commitAudio':
        final ids = params['audioIds'];
        if (ids is! List) throw const FormatException('缺少音频编号。');
        await LiveAudioArchive.instance.commit(ids.whereType<String>());
        return <String, Object?>{'status': 'saved'};
      case 'live.listRecordings':
        final rows = await _playbackChannel.invokeListMethod<Object?>(
          'listRecordings',
        );
        return <String, Object?>{'recordings': rows ?? <Object?>[]};
      case 'live.openRecording':
        final uri = params['uri'];
        if (uri is! String || uri.isEmpty) {
          throw const FormatException('缺少录制文件。');
        }
        final result = await _playbackChannel
            .invokeMethod<Map<Object?, Object?>>('openRecording', <String, Object?>{
              'uri': uri,
            });
        return Map<String, Object?>.from(result ?? const <Object?, Object?>{});
      case 'live.startPlayback':
        if (_liveActive) return <String, Object?>{'status': 'already_active'};
        final source = params['sourceTag'];
        final target = params['targetTag'];
        if (source is! String || target is! String || source == target) {
          throw const FormatException('请选择两个不同的翻译语言。');
        }
        _liveSourceTag = source;
        _liveTargetTag = target;
        _liveMode = 'playback';
        unawaited(_preparePlaybackPreview(source, target));
        _liveStopping = false;
        _liveEntries.clear();
        _sessionAudioIds.clear();
        _liveRecordAudio = params['recordAudio'] == true;
        _liveRecordingSessionId = 'live-${DateTime.now().microsecondsSinceEpoch}';
        _liveMicrophoneStartedAtMs = null;
        _lastLiveRecording = null;
        _liveRecordingError = null;
        _latestOverlayCapturedAtMs = 0;
        _playbackStopped = Completer<void>();
        _livePendingEnd = false;
        _playbackCaptureSessionId = null;
        _resetLivePreviews();
        final overlay = await _subtitleChannel
            .invokeMethod<Map<Object?, Object?>>('start', <String, Object?>{
              'preferences': overlayPrefs,
            });
        if (overlay?['status'] != 'started') {
          _liveMode = null;
          return <String, Object?>{'status': 'overlay_permission_requested'};
        }
        try {
          final raw = await _playbackChannel.invokeMethod<Map<Object?, Object?>>(
            'startCapture',
            <String, Object?>{
              'recordSession': true,
              'recordingSessionId': _liveRecordingSessionId,
              'recordScreen': true,
              'recordPlaybackAudio': true,
            },
          );
          _liveActive = true;
          return <String, Object?>{
            'status': raw?['status'] ?? 'permission_requested',
          };
        } catch (_) {
          await _subtitleChannel.invokeMethod<void>('stop');
          _liveMode = null;
          rethrow;
        }
      case 'live.stopPlayback':
        _liveStopping = true;
        await _playbackChannel.invokeMethod<Object?>('stopCapture');
        await _awaitPlaybackFlush();
        await _playbackRecognitionQueue;
        await _playbackQueue;
        await _endPlaybackSession();
        return <String, Object?>{'status': 'stopped', 'entries': _liveEntries,
          'recording': _lastLiveRecording, 'recordingError': _liveRecordingError};
      case 'live.startMic':
        if (_liveActive) return <String, Object?>{'status': 'already_active'};
        final source = params['sourceTag'];
        final target = params['targetTag'];
        if (source is! String || target is! String || source == target) {
          throw const FormatException('请选择两个不同的翻译语言。');
        }
        _liveSourceTag = source;
        _liveTargetTag = target;
        _liveMode = 'mic';
        _liveStopping = false;
        _liveEntries.clear();
        _sessionAudioIds.clear();
        _liveRecordAudio = params['recordAudio'] == true;
        _liveRecordingSessionId = 'live-${DateTime.now().microsecondsSinceEpoch}';
        _liveMicrophoneStartedAtMs = null;
        _lastLiveRecording = null;
        _liveRecordingError = null;
        _latestOverlayCapturedAtMs = 0;
        _livePendingEnd = false;
        _playbackCaptureSessionId = null;
        _playbackStopped = Completer<void>();
        _resetLivePreviews();
        final overlay = await _subtitleChannel
            .invokeMethod<Map<Object?, Object?>>('start', <String, Object?>{
              'preferences': overlayPrefs,
            });
        if (overlay?['status'] != 'started') {
          _liveMode = null;
          return <String, Object?>{'status': 'overlay_permission_requested'};
        }
        final id = 'live-mic-${DateTime.now().microsecondsSinceEpoch}';
        try {
          _liveMicrophoneRecorder = await LiveSessionMicrophoneRecorder.start(
            _liveRecordingSessionId!,
          );
          final started = await MiyinOfflineSpeechRecognizer.instance
              .startListening(
                sessionId: id,
                mode: 'video',
                sourceTag: source,
                targetTag: target,
                retainLiveAudio: _liveRecordAudio,
                onLivePcm: _captureLiveMicrophonePcm,
              );
          if (started['status'] != 'listening') {
            throw const FormatException('麦克风未能开始识别。');
          }
          await _microphoneSessionChannel.invokeMethod<Object?>('start');
          _liveActive = true;
          _micSessionId = id;
          final generation = ++_micGeneration;
          _micLoopTask = _runMicLoop(generation);
          final projection = await _playbackChannel
              .invokeMethod<Map<Object?, Object?>>('startCapture',
                  <String, Object?>{
                'recordSession': true,
                'recordingSessionId': _liveRecordingSessionId,
                'recordScreen': true,
                'recordPlaybackAudio': false,
              });
          return <String, Object?>{
            'status': projection?['status'] ?? 'permission_requested',
          };
        } catch (_) {
          await MiyinOfflineSpeechRecognizer.instance.cancelListening(
            sessionId: id,
          );
          await _subtitleChannel.invokeMethod<void>('stop');
          await _liveMicrophoneRecorder?.discard();
          _liveMicrophoneRecorder = null;
          _liveMode = null;
          rethrow;
        }
      case 'live.stopMic':
        _liveStopping = true;
        await _stopMicCapture();
        await _micTranslationQueue;
        await _endPlaybackSession();
        return <String, Object?>{'status': 'stopped', 'entries': _liveEntries,
          'recording': _lastLiveRecording, 'recordingError': _liveRecordingError};
      case 'live.startConference':
        if (_liveActive) return <String, Object?>{'status': 'already_active'};
        final source = params['sourceTag'];
        final target = params['targetTag'];
        if (source is! String || target is! String || source == target) {
          throw const FormatException('请选择两个不同的翻译语言。');
        }
        _liveSourceTag = source;
        _liveTargetTag = target;
        _liveMode = 'conference';
        _liveStopping = false;
        _liveEntries.clear();
        _sessionAudioIds.clear();
        _liveRecordAudio = params['recordAudio'] == true;
        _liveRecordingSessionId = 'live-${DateTime.now().microsecondsSinceEpoch}';
        _liveMicrophoneStartedAtMs = null;
        _lastLiveRecording = null;
        _liveRecordingError = null;
        _latestOverlayCapturedAtMs = 0;
        _playbackStopped = Completer<void>();
        _livePendingEnd = false;
        _playbackCaptureSessionId = null;
        _resetLivePreviews();
        final overlay = await _subtitleChannel
            .invokeMethod<Map<Object?, Object?>>('start', <String, Object?>{
              'preferences': overlayPrefs,
            });
        if (overlay?['status'] != 'started') {
          _liveMode = null;
          return <String, Object?>{'status': 'overlay_permission_requested'};
        }
        final id = 'live-mic-${DateTime.now().microsecondsSinceEpoch}';
        try {
          _liveMicrophoneRecorder = await LiveSessionMicrophoneRecorder.start(
            _liveRecordingSessionId!,
          );
          final started = await MiyinOfflineSpeechRecognizer.instance
              .startListening(
                sessionId: id,
                mode: 'video',
                sourceTag: source,
                targetTag: target,
                retainLiveAudio: _liveRecordAudio,
                onLivePcm: _captureLiveMicrophonePcm,
              );
          if (started['status'] != 'listening') {
            throw const FormatException('麦克风未能开始识别。');
          }
          await _microphoneSessionChannel.invokeMethod<Object?>('start');
          _liveActive = true;
          _micSessionId = id;
          final generation = ++_micGeneration;
          _micLoopTask = _runMicLoop(generation);
        } catch (_) {
          await _liveMicrophoneRecorder?.discard();
          _liveMicrophoneRecorder = null;
          await MiyinOfflineSpeechRecognizer.instance.cancelListening(
            sessionId: id,
          );
          await _endPlaybackSession();
          rethrow;
        }
        unawaited(_preparePlaybackPreview(source, target));
        try {
          final raw = await _playbackChannel.invokeMethod<Map<Object?, Object?>>(
            'startCapture',
            <String, Object?>{
              'recordSession': true,
              'recordingSessionId': _liveRecordingSessionId,
              'recordScreen': true,
              'recordPlaybackAudio': true,
            },
          );
          return <String, Object?>{
            'status': raw?['status'] ?? 'permission_requested',
          };
        } catch (error) {
          _liveMode = 'mic';
          await _emitLiveEvent('error', message: '其他 App 音频未能启动，麦克风同传继续运行');
          return <String, Object?>{
            'status': 'mic_fallback',
            'message': '$error',
          };
        }
      case 'live.stopConference':
        _liveStopping = true;
        final micStop = _stopMicCapture();
        if (_liveMode == 'conference' || _liveMode == 'playback') {
          try {
            await _playbackChannel.invokeMethod<Object?>('stopCapture');
            await _awaitPlaybackFlush();
          } catch (error) {
            debugPrint('Could not stop media capture cleanly: $error');
          }
        }
        await micStop;
        await _playbackRecognitionQueue;
        await _playbackQueue;
        await _micTranslationQueue;
        await _endPlaybackSession();
        return <String, Object?>{'status': 'stopped', 'entries': _liveEntries,
          'recording': _lastLiveRecording, 'recordingError': _liveRecordingError};
      case 'live.status':
        final playbackStatus =
            (_liveMode == 'playback' || _liveMode == 'conference')
            ? await _playbackChannel.invokeMethod<Map<Object?, Object?>>(
                'status',
              )
            : null;
        return <String, Object?>{
          'active': _liveActive,
          'mode': _liveMode,
          'playbackCapturing': playbackStatus?['running'] == true,
          'playbackPermissionRequested':
              playbackStatus?['permissionRequested'] == true,
          'sourceTag': _liveSourceTag,
          'targetTag': _liveTargetTag,
          'entries': _liveEntries,
        };
      case 'live.configureOverlay':
        await _subtitleChannel.invokeMethod<void>(
          'configure',
          <String, Object?>{'preferences': overlayPrefs},
        );
        return <String, Object?>{'status': 'updated'};
      default:
        throw const FormatException('Unknown live subtitle request.');
    }
  }

  void _resetLivePreviews() {
    _livePreviewGeneration++;
    for (final timer in _livePreviewTimers.values) {
      timer.cancel();
    }
    _livePreviewTimers.clear();
    _livePreviewText.clear();
    _livePreviewSession.clear();
    _livePreviewBusy.clear();
  }

  void _finishLivePreview(String audioSource, String previewSessionId) {
    if (_livePreviewSession[audioSource] != previewSessionId) return;
    _livePreviewTimers.remove(audioSource)?.cancel();
    _livePreviewText.remove(audioSource);
    _livePreviewSession.remove(audioSource);
  }

  void _onLivePreview(String audioSource, String text, String previewSessionId) {
    if (!_liveActive || _liveStopping || text.trim().isEmpty ||
        _isRepetitiveAudioArtifact(text)) return;
    if (_livePreviewSession[audioSource] != previewSessionId) {
      _livePreviewTimers.remove(audioSource)?.cancel();
    }
    _livePreviewSession[audioSource] = previewSessionId;
    _livePreviewText[audioSource] = text.trim();
    unawaited(_emitLiveEvent(
      'recognition_partial',
      text: text,
      audioSource: audioSource,
      previewSessionId: previewSessionId,
    ));
    _scheduleLivePreviewTranslation(audioSource);
  }

  void _scheduleLivePreviewTranslation(String audioSource) {
    if (_livePreviewBusy.containsKey(audioSource) ||
        _livePreviewTimers.containsKey(audioSource) ||
        !_liveActive ||
        _liveStopping) return;
    final text = _livePreviewText[audioSource] ?? '';
    final latinWords = RegExp(r'[A-Za-z]+').allMatches(text).length;
    final hanCount = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
    if (latinWords < 4 && hanCount < 5) return;
    _livePreviewTimers[audioSource] = Timer(const Duration(seconds: 2), () {
      _livePreviewTimers.remove(audioSource);
      unawaited(_translateLivePreview(audioSource));
    });
  }

  Future<void> _translateLivePreview(String audioSource) async {
    if (_livePreviewBusy.containsKey(audioSource)) return;
    final text = _livePreviewText[audioSource];
    final previewSessionId = _livePreviewSession[audioSource];
    if (text == null || previewSessionId == null || !_liveActive || _liveStopping) return;
    final recognizedLanguage = _resolveLiveDetectedLanguage(text, '');
    var source = _liveSourceTag;
    var target = _liveTargetTag;
    if (recognizedLanguage == target) {
      source = _liveTargetTag;
      target = _liveSourceTag;
    } else if (recognizedLanguage != source) {
      return;
    }
    final generation = _livePreviewGeneration;
    _livePreviewBusy[audioSource] = generation;
    try {
      final response = await (await _getRpcRouter()).handle(jsonEncode(<String, Object?>{
        'version': 1,
        'id': 'live-preview-${DateTime.now().microsecondsSinceEpoch}',
        'method': 'translation.preview',
        'params': <String, Object?>{
          'sourceTag': source,
          'targetTag': target,
          'text': text,
        },
      }));
      final translated = response['result'] is Map
          ? (response['result'] as Map)['translatedText']?.toString().trim() ?? ''
          : '';
      if (response['ok'] == true && translated.isNotEmpty &&
          generation == _livePreviewGeneration && _liveActive && !_liveStopping &&
          _livePreviewSession[audioSource] == previewSessionId &&
          (_livePreviewText[audioSource]?.startsWith(text) ?? false)) {
        await _updateLiveOverlayPartial(
          text,
          audioSource: audioSource,
          translation: translated,
        );
        await _emitLiveEvent(
          'translation_partial',
          text: translated,
          audioSource: audioSource,
          previewSessionId: previewSessionId,
        );
      }
    } catch (error) {
      debugPrint('Live draft translation unavailable: $error');
    } finally {
      if (_livePreviewBusy[audioSource] == generation) {
        _livePreviewBusy.remove(audioSource);
      }
      if (generation == _livePreviewGeneration &&
          _livePreviewSession[audioSource] == previewSessionId &&
          _livePreviewText[audioSource] != text) {
        _scheduleLivePreviewTranslation(audioSource);
      }
    }
  }

  Future<void> _runMicLoop(int generation) async {
    while (_liveActive &&
        !_liveStopping &&
        (_liveMode == 'mic' || _liveMode == 'conference') &&
        generation == _micGeneration) {
      final wake = Completer<void>();
      _micLoopWake = wake;
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(const Duration(milliseconds: 250)),
        wake.future,
      ]);
      if (identical(_micLoopWake, wake)) _micLoopWake = null;
      if (!_liveActive || _liveStopping || generation != _micGeneration) break;
      final id = _micSessionId;
      if (id == null) break;
      if (!MiyinOfflineSpeechRecognizer.instance.shouldFinalizeLiveSegment(
        sessionId: id,
      )) {
        continue;
      }
      try {
        _finishLivePreview('mic',
            '$id:${MiyinOfflineSpeechRecognizer.instance.currentLiveSegmentIndex}');
        final capturedEndMs = DateTime.now().millisecondsSinceEpoch;
        final ongoing = await MiyinOfflineSpeechRecognizer.instance
            .takeLiveSegment(sessionId: id);
        if (ongoing['status'] == 'processed') {
          final text = ongoing['text']?.toString().trim() ?? '';
          if (text.isNotEmpty) {
            _queueMicTranslation(
              text,
              ongoing['languageTag']?.toString() ?? '',
              capturedEndMs - (ongoing['durationMs'] as int? ?? 0),
              audioId: ongoing['audioId']?.toString(),
            );
          }
          continue;
        }
        if (ongoing['status'] != 'unsupported') {
          throw StateError('麦克风分段识别状态异常：${ongoing['status']}');
        }
        // The bilingual streaming fallback cannot detach a segment yet.
        final result = await MiyinOfflineSpeechRecognizer.instance
            .stopListening(sessionId: id);
        if (_micSessionId == id) _micSessionId = null;
        final text = result['text']?.toString().trim() ?? '';
        final tag = result['languageTag']?.toString() ?? '';
        if (text.isNotEmpty) {
          _queueMicTranslation(
            text,
            tag,
            capturedEndMs - (result['durationMs'] as int? ?? 0),
            audioId: result['audioId']?.toString(),
          );
        }
        if (!_liveActive || _liveStopping || generation != _micGeneration)
          break;
        final nextId = 'live-mic-${DateTime.now().microsecondsSinceEpoch}';
        final started = await MiyinOfflineSpeechRecognizer.instance
            .startListening(
              sessionId: nextId,
              mode: 'video',
              sourceTag: _liveSourceTag,
              targetTag: _liveTargetTag,
              retainLiveAudio: _liveRecordAudio,
                onLivePcm: _captureLiveMicrophonePcm,
            );
        if (started['status'] != 'listening') break;
        _micSessionId = nextId;
      } catch (error) {
        await _emitLiveEvent('error', message: '麦克风同传中断：$error');
        break;
      }
    }
    if (_liveActive &&
        !_liveStopping &&
        (_liveMode == 'mic' || _liveMode == 'conference') &&
        generation == _micGeneration) {
      if (_liveMode == 'conference') {
        _liveMode = 'playback';
        final id = _micSessionId;
        _micSessionId = null;
        if (id != null) {
          try {
            await MiyinOfflineSpeechRecognizer.instance.cancelListening(
              sessionId: id,
            );
          } catch (_) {
            /* session may already be closed */
          }
        }
        try {
          await _microphoneSessionChannel.invokeMethod<void>('stop');
        } catch (_) {
          /* playback can continue */
        }
        await _emitLiveEvent('error', message: '麦克风同传已停止，其他 App 音频继续运行');
      } else {
        Timer.run(() {
          unawaited(_endPlaybackSession());
        });
      }
    }
  }

  void _queueMicTranslation(
    String text,
    String tag,
    int capturedAtMs, {
    String? audioId,
  }) {
    if (audioId != null) _sessionAudioIds.add(audioId);
    _micTranslationQueue = _micTranslationQueue
        .then(
          (_) => _translateLiveText(
            text,
            tag,
            audioSource: 'mic',
            capturedAtMs: capturedAtMs,
            audioId: audioId,
          ),
        )
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Microphone subtitle segment failed: $error');
          unawaited(_emitLiveEvent('error', message: '这一段麦克风声音未能翻译。'));
        });
  }

  Future<void> _stopMicCapture() async {
    _micGeneration++;
    final wake = _micLoopWake;
    if (wake != null && !wake.isCompleted) wake.complete();
    final loopTask = _micLoopTask;
    if (loopTask != null) await loopTask;
    _micLoopTask = null;
    final id = _micSessionId;
    _micSessionId = null;
    if (id == null) return;
    _finishLivePreview('mic',
        '$id:${MiyinOfflineSpeechRecognizer.instance.currentLiveSegmentIndex}');
    final capturedEndMs = DateTime.now().millisecondsSinceEpoch;
    try {
      final result = await MiyinOfflineSpeechRecognizer.instance.stopListening(
        sessionId: id,
      );
      final text = result['text']?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        _queueMicTranslation(
          text,
          result['languageTag']?.toString() ?? '',
          capturedEndMs - (result['durationMs'] as int? ?? 0),
          audioId: result['audioId']?.toString(),
        );
      }
    } catch (error) {
      await _emitLiveEvent('error', message: '最后一段麦克风声音未能识别：$error');
    }
  }

  void _captureLiveMicrophonePcm(Uint8List pcm) {
    try {
      if (pcm.isNotEmpty && _liveMicrophoneRecorder != null) {
        _liveMicrophoneStartedAtMs ??= DateTime.now().millisecondsSinceEpoch;
      }
      _liveMicrophoneRecorder?.add(pcm);
    } catch (error) {
      _liveRecordingError = '麦克风整场录音写入失败：$error';
      debugPrint(_liveRecordingError);
    }
  }

  Future<void> _awaitPlaybackFlush() async {
    final flushed = _playbackStopped;
    if (flushed == null) return;
    try {
      await flushed.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      debugPrint('Playback capture flush did not finish within two seconds.');
    }
  }

  Future<void> _preparePlaybackPreview(String source, String target) async {
    final generation = ++_playbackPreviewGeneration;
    _playbackPreviewPrepared = false;
    final ready = await MiyinOfflineSpeechRecognizer.instance
        .startPlaybackPreview(sourceTag: source, targetTag: target);
    if (generation == _playbackPreviewGeneration &&
        !_liveStopping &&
        (_liveMode == 'playback' || _liveMode == 'conference')) {
      _playbackPreviewPrepared = ready;
    } else if (generation == _playbackPreviewGeneration) {
      MiyinOfflineSpeechRecognizer.instance.stopPlaybackPreview();
    }
  }

  void _stopPlaybackPreview() {
    _playbackPreviewGeneration++;
    _playbackPreviewPrepared = false;
    MiyinOfflineSpeechRecognizer.instance.stopPlaybackPreview();
  }

  void _onPlaybackCaptureEvent(Object? raw) {
    if (raw is! Map) return;
    final event = Map<String, Object?>.from(raw);
    final type = event['type'];
    final captureSessionId = event['captureSessionId'];
    if (type == 'capture_started' && captureSessionId is String) {
      _playbackCaptureSessionId = captureSessionId;
    } else if (captureSessionId is String &&
        captureSessionId != _playbackCaptureSessionId) {
      // A previous MediaProjection service can finish posting audio events
      // after a new conference session has already started.
      return;
    }
    if (type == 'capture_audio' &&
        _playbackPreviewPrepared &&
        _liveActive &&
        (_liveMode == 'playback' || _liveMode == 'conference') &&
        event['pcm'] is Uint8List &&
        event['segmentId'] is int) {
      final preview = MiyinOfflineSpeechRecognizer.instance
          .acceptPlaybackPreview(
            event['pcm'] as Uint8List,
            event['segmentId'] as int,
          );
      if (preview != null) {
        unawaited(_updateLiveOverlayPartial(preview, audioSource: 'app'));
        _onLivePreview('app', preview,
            '${event['captureSessionId']}:${event['segmentId']}');
      }
      return;
    }
    if (type == 'capture_segment' &&
        event['path'] is String &&
        _liveActive &&
        (_liveMode == 'playback' || _liveMode == 'conference')) {
      final path = event['path'] as String;
      if (event['segmentId'] is int) {
        _finishLivePreview('app',
            '${event['captureSessionId']}:${event['segmentId']}');
        MiyinOfflineSpeechRecognizer.instance.finishPlaybackPreviewSegment(
          event['segmentId'] as int,
        );
      }
      final durationMs = (event['durationMs'] as num?)?.toInt() ?? 0;
      final capturedAtMs = DateTime.now().millisecondsSinceEpoch - durationMs;
      _playbackRecognitionQueue = _playbackRecognitionQueue
          .then((_) => _translatePlaybackFile(path, capturedAtMs: capturedAtMs))
          .catchError((Object error, StackTrace stackTrace) {
            debugPrint('Playback subtitle segment failed: $error');
            unawaited(_emitLiveEvent('error', message: '这一段媒体声音未能翻译。'));
          });
      return;
    }
    if (type == 'capture_started') {
      unawaited(_emitLiveEvent('started', message: _liveMode == 'mic'
          ? '正在保存屏幕与麦克风声音'
          : '正在识别并录制媒体声音'));
    } else if (type == 'recording_saved') {
      _lastLiveRecording = Map<String, Object?>.from(event);
    } else if (type == 'recording_error') {
      _liveRecordingError = event['message']?.toString() ?? '整场录制未能保存。';
      unawaited(_emitLiveEvent('error', message: _liveRecordingError));
    } else if (type == 'capture_flushed') {
      final flushed = _playbackStopped;
      if (flushed != null && !flushed.isCompleted) flushed.complete();
    } else if (type == 'capture_silent') {
      unawaited(
        _emitLiveEvent(
          'silent',
          message: event['message'] as String? ?? '尚未收到可采集的媒体声音',
        ),
      );
    } else if (type == 'capture_error') {
      if (event['code'] != 'segment_write_failed') _stopPlaybackPreview();
      unawaited(
        _emitLiveEvent(
          'error',
          message: event['message'] as String? ?? '媒体声音采集失败',
        ),
      );
      if (event['code'] == 'segment_write_failed') return;
      final flushed = _playbackStopped;
      if (flushed != null && !flushed.isCompleted) flushed.complete();
      if ((_liveMode == 'conference' || _liveMode == 'mic') && !_liveStopping) {
        _liveMode = 'mic';
      } else if (!_liveStopping) {
        unawaited(_endPlaybackSession());
      }
    } else if (type == 'capture_stopped') {
      _stopPlaybackPreview();
      if ((_liveMode == 'conference' || _liveMode == 'mic') && !_liveStopping) {
        _liveMode = 'mic';
        unawaited(_emitLiveEvent('error', message: '屏幕录制已停止，麦克风同传继续运行'));
      } else if (!_liveStopping) {
        unawaited(_playbackRecognitionQueue.then((_) => _endPlaybackSession()));
      }
    }
  }

  Future<void> _translatePlaybackFile(
    String path, {
    required int capturedAtMs,
  }) async {
    try {
      final recognized = await MiyinOfflineSpeechRecognizer.instance
          .transcribePlaybackSegment(path);
      if (!_liveActive) return;
      final text = (recognized['text'] ?? '').trim();
      if (text.isEmpty) return;
      final detected = recognized['languageTag'] ?? '';
      String? audioId;
      if (_liveRecordAudio) {
        try {
          audioId = await LiveAudioArchive.instance.retainPlaybackFile(path);
          _sessionAudioIds.add(audioId);
        } catch (error) {
          debugPrint('Could not retain conference playback clip: $error');
        }
      }
      _playbackQueue = _playbackQueue
          .then((_) => _translateLiveText(
                text,
                detected,
                audioSource: 'app',
                capturedAtMs: capturedAtMs,
                audioId: audioId,
              ))
          .catchError((Object error, StackTrace stackTrace) {
            debugPrint('Playback subtitle translation failed: $error');
            unawaited(_emitLiveEvent('error', message: '这一段媒体声音未能翻译。'));
          });
    } finally {
      try {
        await File(path).delete();
      } catch (_) {
        /* cache cleanup */
      }
    }
  }

  Future<void> _translateLiveText(
    String text,
    String detected, {
    required String audioSource,
    required int capturedAtMs,
    String? audioId,
  }) async {
    final spoken = text.trim();
    if (spoken.isEmpty ||
        RegExp(
          r'^(?:\[|\()\s*(music|applause|laughter|laughing|noise|silence|background music|inaudible)\s*(?:\]|\))$',
          caseSensitive: false,
        ).hasMatch(spoken) ||
        RegExp(r'^[（【]\s*(笑|音乐|掌声|噪音|静音)\s*[）】]$').hasMatch(spoken) ||
        _isRepetitiveAudioArtifact(spoken))
      return;
    final spokenLanguage = _resolveLiveDetectedLanguage(spoken, detected);
    var source = _liveSourceTag;
    var target = _liveTargetTag;
    if (spokenLanguage == target) {
      source = _liveTargetTag;
      target = _liveSourceTag;
    } else if (spokenLanguage.isNotEmpty && spokenLanguage != source) {
      await _publishLiveEntry(
        text: spoken,
        translation: '识别语种不在当前翻译组合中',
        sourceTag: spokenLanguage,
        targetTag: target,
        audioSource: audioSource,
        capturedAtMs: capturedAtMs,
        audioId: audioId,
      );
      await _emitLiveEvent('unsupported_language', message: '已保留原声与识别文字；当前语种无法翻译');
      return;
    }
    final request = jsonEncode(<String, Object?>{
      'version': 1,
      'id': 'live-${DateTime.now().microsecondsSinceEpoch}',
      'method': 'translation.preview',
      'params': <String, Object?>{
        'sourceTag': source,
        'targetTag': target,
        'text': text,
      },
    });
    late final Map<String, Object?> response;
    try {
      response = await (await _getRpcRouter()).handle(request);
    } catch (error) {
      debugPrint('Live subtitle translation failed: $error');
      await _publishLiveEntry(
        text: spoken,
        translation: '译文暂不可用',
        sourceTag: source,
        targetTag: target,
        audioSource: audioSource,
        capturedAtMs: capturedAtMs,
        audioId: audioId,
      );
      await _emitLiveEvent('error', message: '这一段语音暂未译出，原声与文字已保留');
      return;
    }
    if (response['ok'] != true || response['result'] is! Map) {
      await _publishLiveEntry(
        text: spoken,
        translation: '译文暂不可用',
        sourceTag: source,
        targetTag: target,
        audioSource: audioSource,
        capturedAtMs: capturedAtMs,
        audioId: audioId,
      );
      await _emitLiveEvent('error', message: '当前语言的离线翻译暂不可用');
      return;
    }
    final translated =
        (response['result'] as Map)['translatedText']?.toString().trim() ?? '';
    await _publishLiveEntry(
      text: spoken,
      translation: translated.isEmpty ? '译文暂不可用' : translated,
      sourceTag: source,
      targetTag: target,
      audioSource: audioSource,
      capturedAtMs: capturedAtMs,
      audioId: audioId,
    );
  }

  Future<void> _publishLiveEntry({
    required String text,
    required String translation,
    required String sourceTag,
    required String targetTag,
    required String audioSource,
    required int capturedAtMs,
    String? audioId,
  }) async {
    final entry = <String, String>{
      'sourceText': text,
      'translatedText': translation,
      'sourceTag': sourceTag,
      'targetTag': targetTag,
      'audioSource': audioSource,
      'capturedAtMs': capturedAtMs.toString(),
      if (audioId != null) 'audioId': audioId,
    };
    _liveEntries.add(entry);
    _liveEntries.sort(
      (a, b) => (int.tryParse(a['capturedAtMs'] ?? '') ?? 0).compareTo(
        int.tryParse(b['capturedAtMs'] ?? '') ?? 0,
      ),
    );
    if (capturedAtMs >= _latestOverlayCapturedAtMs) {
      _latestOverlayCapturedAtMs = capturedAtMs;
      await _subtitleChannel.invokeMethod<void>('update', <String, Object?>{
        'source': text,
        'translation': translation,
      });
    }
    await _emitLiveEvent('segment', entry: entry);
  }

  String _resolveLiveDetectedLanguage(String text, String detected) {
    // Cyrillic and kana disambiguate Russian/Japanese more reliably than a
    // short Whisper clip's language label. Han-only text is ambiguous.
    if (RegExp(r'[\u0400-\u04ff]').hasMatch(text) &&
        (_liveSourceTag == 'ru' || _liveTargetTag == 'ru')) {
      return 'ru';
    }
    if (RegExp(r'[\u3040-\u30ff]').hasMatch(text) &&
        (_liveSourceTag == 'ja' || _liveTargetTag == 'ja')) {
      return 'ja';
    }
    if (!((_liveSourceTag == 'zh-Hans' && _liveTargetTag == 'en') ||
        (_liveSourceTag == 'en' && _liveTargetTag == 'zh-Hans'))) {
      return detected;
    }
    // Whisper's language label is unstable for short conference clips. Only
    // override it when the recognized writing system is unambiguous for this
    // Chinese-English pair. Keep genuinely unsupported scripts unsupported.
    final latinWords = RegExp(r'[A-Za-z]+').allMatches(text).length;
    final hanCount = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
    final hasHan = hanCount > 0;
    final hasOtherScripts = RegExp(r'[\u3040-\u30ff\u0400-\u04ff]')
        .hasMatch(text);
    if (!hasHan && !hasOtherScripts &&
        (latinWords >= 2 ||
            RegExp(r'^(?:hi|hello|thanks|thank you|yes|no)[.!?\s]*$',
              caseSensitive: false,
            ).hasMatch(text))) {
      return 'en';
    }
    // For a Chinese-English session, Han text without kana is stronger
    // evidence than a third-language label from a very short audio clip.
    // This also keeps a short code-switched reply such as "Hi, 你好" usable.
    if (!hasOtherScripts && latinWords <= 1 && hanCount >= 2) {
      return 'zh-Hans';
    }
    return detected;
  }

  bool _isRepetitiveAudioArtifact(String text) {
    // Whisper can turn steady noise into the same short phrase over and over.
    // Token frequency alone misses Chinese text and multi-word loops such as
    // "I call you". Require a long, overwhelmingly repeated phrase so normal
    // short replies are kept.
    final compact = text.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9\u4e00-\u9fff]+'),
      '',
    );
    if (compact.length >= 24) {
      final longestUnit = (compact.length ~/ 5).clamp(2, 24);
      for (var unitLength = 2; unitLength <= longestUnit; unitLength++) {
        for (var start = 0; start < unitLength && start + unitLength <= compact.length; start++) {
          final unit = compact.substring(start, start + unitLength);
          var cursor = start;
          var repetitions = 0;
          while (true) {
            final index = compact.indexOf(unit, cursor);
            if (index < 0) break;
            repetitions++;
            cursor = index + unitLength;
          }
          if (repetitions >= 5 &&
              repetitions * unitLength * 10 >= compact.length * 7) {
            return true;
          }
        }
      }
    }
    final tokens = text
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (tokens.length < 7) return false;
    final counts = <String, int>{};
    for (final token in tokens) {
      final normalized = token.toLowerCase().replaceAll(
        RegExp(r'[.,!?，。！？:;；：]+$'),
        '',
      );
      if (normalized.isNotEmpty)
        counts[normalized] = (counts[normalized] ?? 0) + 1;
    }
    if (counts.isEmpty) return false;
    final highest = counts.values.reduce((a, b) => a > b ? a : b);
    return highest >= 5 && highest * 10 >= tokens.length * 6;
  }

  Future<void> _endPlaybackSession() async {
    if (!_liveActive && _liveMode == null) return;
    _liveStopping = true;
    _resetLivePreviews();
    _stopPlaybackPreview();
    _micGeneration++;
    final wake = _micLoopWake;
    if (wake != null && !wake.isCompleted) wake.complete();
    final loopTask = _micLoopTask;
    if (loopTask != null) await loopTask;
    _micLoopTask = null;
    final id = _micSessionId;
    _micSessionId = null;
    if (id != null) {
      try {
        await MiyinOfflineSpeechRecognizer.instance.cancelListening(
          sessionId: id,
        );
      } catch (_) {
        /* already stopped */
      }
    }
    if (_liveRecordingSessionId != null) {
      try {
        await _playbackChannel.invokeMethod<Object?>('stopCapture');
      } catch (_) {
        /* already stopped */
      }
      // The native recorder can emit its final segment after stopCapture
      // returns. Wait for that segment to reach the Dart queue before saving
      // the session, including when capture ended unexpectedly.
      await _awaitPlaybackFlush();
    }
    await _playbackRecognitionQueue;
    await _playbackQueue;
    await _micTranslationQueue;
    await _finalizeLiveRecording();
    final attachedAudioIds = _liveEntries
        .map((entry) => entry['audioId'])
        .whereType<String>()
        .toSet();
    final unusedAudioIds = _sessionAudioIds.difference(attachedAudioIds);
    if (unusedAudioIds.isNotEmpty) {
      try {
        await LiveAudioArchive.instance.delete(unusedAudioIds);
      } catch (error) {
        debugPrint('Could not remove unused conference clips: $error');
      }
    }
    _sessionAudioIds.clear();
    _liveActive = false;
    if (_liveMode == 'mic' || _liveMode == 'conference') {
      try {
        await _microphoneSessionChannel.invokeMethod<void>('stop');
      } catch (_) {
        /* already stopped */
      }
    }
    _liveMode = null;
    _liveRecordingSessionId = null;
    _liveMicrophoneStartedAtMs = null;
    _playbackCaptureSessionId = null;
    _playbackStopped = null;
    _liveStopping = false;
    try {
      await _subtitleChannel.invokeMethod<void>('stop');
    } catch (_) {
      /* service may have exited */
    }
    _livePendingEnd = true;
    await _emitLiveEvent('ended', message: '本次同传已结束');
  }

  Future<void> _finalizeLiveRecording() async {
    final sessionId = _liveRecordingSessionId;
    if (sessionId == null) return;
    final mic = _liveMicrophoneRecorder;
    _liveMicrophoneRecorder = null;
    if (mic != null) {
      try {
        final file = await mic.finish();
        if (file != null) {
          await _playbackChannel.invokeMethod<Map<Object?, Object?>>(
            'publishMicrophoneRecording',
            <String, Object?>{
              'recordingSessionId': sessionId,
              'path': file.path,
              'microphoneStartedAtMs': _liveMicrophoneStartedAtMs,
            },
          );
          await file.delete();
        }
      } catch (error) {
        _liveRecordingError = '麦克风整场录音保存失败：$error';
        debugPrint(_liveRecordingError);
      }
    }
    if (mic == null) {
      try {
        await _playbackChannel.invokeMethod<Map<Object?, Object?>>(
          'composeRecording',
          <String, Object?>{'recordingSessionId': sessionId},
        );
      } catch (error) {
        _liveRecordingError ??= '有声录屏合成失败，已保留画面和分轨音频：$error';
        debugPrint(_liveRecordingError);
      }
    }
    try {
      final rows = await _playbackChannel.invokeListMethod<Object?>(
        'listRecordings',
      );
      for (final row in rows ?? const <Object?>[]) {
        if (row is! Map || row['recordingSessionId'] != sessionId) continue;
        _lastLiveRecording = Map<String, Object?>.from(row);
        break;
      }
    } catch (error) {
      _liveRecordingError ??= '录制文件已保存，但觅音暂时无法读取文件目录：$error';
    }
  }

  Future<void> _emitLiveEvent(
    String type, {
    String? message,
    String? text,
    String? audioSource,
    String? previewSessionId,
    Map<String, String>? entry,
  }) async {
    if (!_nativeHostReady || !_appVisible) return;
    final detail = <String, Object?>{
      'type': type,
      if (message != null) 'message': message,
      if (text != null) 'text': text,
      if (audioSource != null) 'audioSource': audioSource,
      if (previewSessionId != null) 'previewSessionId': previewSessionId,
      if (entry != null) 'entry': entry,
      'entries': _liveEntries,
      'active': _liveActive,
      if (type == 'ended' && _lastLiveRecording != null)
        'recording': _lastLiveRecording,
      if (type == 'ended' && _liveRecordingError != null)
        'recordingError': _liveRecordingError,
    };
    final literal = jsonEncode(jsonEncode(detail));
    try {
      await _controller.runJavaScript(
        'window.dispatchEvent(new CustomEvent("miyin:playback-subtitle", {detail:JSON.parse($literal)}));',
      );
      if (type == 'ended') _livePendingEnd = false;
    } catch (error) {
      debugPrint('Could not display playback subtitle: $error');
    }
  }

  Future<void> _updateLiveOverlayPartial(
    String text, {
    required String audioSource,
    String? translation,
  }) async {
    if (!_liveActive || _liveStopping || text.trim().isEmpty ||
        _isRepetitiveAudioArtifact(text)) return;
    try {
      await _subtitleChannel.invokeMethod<void>(
        'updatePartial',
        <String, Object?>{
          'source': text,
          'audioSource': audioSource,
          if (translation != null) 'translation': translation,
        },
      );
    } catch (error) {
      debugPrint('Could not update live subtitle preview: $error');
    }
  }

  void _logVoiceEventError(Object error, StackTrace stackTrace) {
    debugPrint('Miyin voice event stream failed: $error');
  }

  Future<void> _forwardVoiceEvent(Object? rawEvent) async {
    if (rawEvent is! Map) return;
    final event = Map<String, Object?>.from(rawEvent);
    if (event['type'] == 'recognition_partial' &&
        event['text'] is String &&
        _isRepetitiveAudioArtifact(event['text'] as String)) return;
    if (event['type'] == 'recognition_partial' &&
        event['sessionId'] is String &&
        (event['sessionId'] as String).startsWith('live-mic-') &&
        (event['sessionId'] != _micSessionId ||
            event['liveSegmentIndex'] !=
                MiyinOfflineSpeechRecognizer.instance.currentLiveSegmentIndex)) {
      return;
    }
    if (event['type'] == 'recognition_partial' &&
        event['sessionId'] == _micSessionId &&
        (_liveMode == 'mic' || _liveMode == 'conference') &&
        event['liveSegmentIndex'] ==
            MiyinOfflineSpeechRecognizer.instance.currentLiveSegmentIndex &&
        event['text'] is String) {
      unawaited(
        _updateLiveOverlayPartial(
          event['text'] as String,
          audioSource: 'mic',
        ),
      );
      _onLivePreview('mic', event['text'] as String,
          '${_micSessionId}:${event['liveSegmentIndex'] ?? 0}');
    }
    if (!_nativeHostReady) return;
    final eventLiteral = jsonEncode(jsonEncode(event));
    try {
      await _controller.runJavaScript('''
        window.dispatchEvent(new CustomEvent(
          "miyin:voice-event",
          { detail: JSON.parse($eventLiteral) }
        ));
      ''');
    } on PlatformException catch (error) {
      debugPrint(
        'Could not forward a voice event to WebView: ${error.message}',
      );
    }
  }

  String? _requestIdFrom(String rawMessage) {
    try {
      final request = jsonDecode(rawMessage);
      if (request is Map && request['id'] is String) {
        final id = request['id'] as String;
        if (id.isNotEmpty && id.length <= 96) return id;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  Future<void> _setNativeHighRefresh(bool active) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await const MethodChannel('com.miyin.app/performance').invokeMethod<void>(
        'setHighRefresh',
        <String, Object>{'active': active},
      );
    } on MissingPluginException catch (error) {
      debugPrint('High refresh request is unavailable: $error');
    } on PlatformException catch (error) {
      debugPrint('High refresh request failed: ${error.message}');
    }
  }

  Future<void> _markNativeHostReady() async {
    _nativeHostReady = true;
    try {
      await _controller.runJavaScript('''
          document.documentElement.dataset.nativeHost = "true";
          (() => {
            if (window.__miyinViewportResizeInstalled) return;
            window.__miyinViewportResizeInstalled = true;
            const root = document.documentElement;
            const viewport = window.visualViewport;
            let resizeFrame = 0;
            let lastHeight = 0;
            let restingHeight = 0;
            const isEditing = () => {
              const element = document.activeElement;
              return element && (element.matches("input, textarea, [contenteditable='true']"));
            };
            const syncVisibleHeight = () => {
              const height = Math.round(viewport?.height || window.innerHeight);
              if (height > 0 && height !== lastHeight) {
                lastHeight = height;
                root.style.setProperty("--miyin-visible-height", height + "px");
              }
              if (!isEditing() && height > restingHeight) restingHeight = height;
              root.dataset.keyboardOpen = isEditing() && restingHeight - height > 110 ? "true" : "false";
            };
            const scheduleVisibleHeight = () => {
              if (resizeFrame) window.cancelAnimationFrame(resizeFrame);
              resizeFrame = window.requestAnimationFrame(() => {
                resizeFrame = 0;
                syncVisibleHeight();
              });
            };
            syncVisibleHeight();
            window.addEventListener("resize", scheduleVisibleHeight, {passive: true});
            viewport?.addEventListener("resize", scheduleVisibleHeight, {passive: true});
            document.addEventListener("focusin", scheduleVisibleHeight, {passive: true});
            document.addEventListener("focusout", scheduleVisibleHeight, {passive: true});
          })();
          window.dispatchEvent(new Event("miyin:native-host-ready"));
          (() => {
            if (window.__miyinRefreshSignalsInstalled) return;
            window.__miyinRefreshSignalsInstalled = true;
            let idleTimer = 0;
            let lastSignalAt = 0;
            const activePointers = new Set();
            const post = active => window.MiyinPerformance?.postMessage(active ? "active" : "idle");
            const scheduleIdle = () => {
              window.clearTimeout(idleTimer);
              idleTimer = window.setTimeout(() => {
                if (activePointers.size === 0 && !window.__miyinVoiceRefreshActive) post(false);
              }, 1100);
            };
            const markActive = () => {
              const now = performance.now();
              if (now - lastSignalAt >= 120) {
                post(true);
                lastSignalAt = now;
              }
              scheduleIdle();
            };
            document.addEventListener("pointerdown", event => {
              activePointers.add(event.pointerId);
              window.__miyinPointerInteractionActive = true;
              window.clearTimeout(idleTimer);
              post(true);
            }, {capture: true, passive: true});
            const releasePointer = event => {
              activePointers.delete(event.pointerId);
              window.__miyinPointerInteractionActive = activePointers.size > 0;
              if (activePointers.size === 0) scheduleIdle();
            };
            document.addEventListener("pointerup", releasePointer, {capture: true, passive: true});
            document.addEventListener("pointercancel", releasePointer, {capture: true, passive: true});
            ["wheel", "keydown", "scroll"].forEach(type => {
              document.addEventListener(type, markActive, {capture: true, passive: true});
            });
            post(false);
            window.dispatchEvent(new Event("miyin:refresh-state-sync"));
            window.dispatchEvent(new Event("miyin:app-resumed"));
          })();
        ''');
    } catch (error) {
      _nativeHostReady = false;
      debugPrint('Could not initialize native performance signals: $error');
    }
    if (_nativeHostReady) {
      try {
        await _syncSubtitleQuickPreferences();
        await _consumeFloatingScreen();
        await _consumeScreenshot();
      } catch (error) {
        debugPrint('Could not route floating shortcut: $error');
      }
      try {
        final recoveredAttachment = await _recoveredAttachment;
        if (recoveredAttachment != null) {
          final recoveredLiteral = jsonEncode(
            jsonEncode(recoveredAttachment.toRpcMap()),
          );
          await _controller.runJavaScript('''
            window.dispatchEvent(new CustomEvent(
              "miyin:native-picker-recovered",
              { detail: JSON.parse($recoveredLiteral) }
            ));
          ''');
        }
      } catch (error) {
        debugPrint('Could not report a recovered picker result: $error');
        try {
          await _controller.runJavaScript(
            'window.dispatchEvent(new Event("miyin:native-picker-recovery-failed"));',
          );
        } on PlatformException catch (javascriptError) {
          debugPrint(
            'Could not report a picker recovery failure: ${javascriptError.message}',
          );
        }
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _openPendingFloatingScreen() async {
    if (!_nativeHostReady || _pendingFloatingScreen == null) return;
    final destination = _pendingFloatingScreen;
    _pendingFloatingScreen = null;
    final captionLanguage = destination == 'video:caption-language';
    final screen = captionLanguage ? 'video' : destination;
    if (screen != 'video' &&
        screen != 'settings' &&
        screen != 'home' &&
        screen != 'floating-settings') {
      return;
    }
    final literal = jsonEncode(screen);
    await _controller.runJavaScript(
      'window.dispatchEvent(new CustomEvent("miyin:open-screen", {detail:{screen:$literal}}));',
    );
    if (captionLanguage) {
      await _controller.runJavaScript(
        'window.dispatchEvent(new Event("miyin:open-caption-language"));',
      );
    }
  }

  Future<void> _dispatchSubtitleQuickPreferences(Map<String, String> changed) async {
    if (!_nativeHostReady || changed.isEmpty) return;
    final detail = jsonEncode(changed);
    await _controller.runJavaScript(
      'window.dispatchEvent(new CustomEvent("miyin:caption-quick-preferences", {detail:$detail}));',
    );
  }

  Future<void> _syncSubtitleQuickPreferences() async {
    if (!_nativeHostReady) return;
    try {
      final saved = await _subtitleChannel.invokeMethod<Map<Object?, Object?>>(
        'quickPreferences',
      );
      if (saved == null || saved.isEmpty) return;
      final changed = <String, String>{};
      saved.forEach((key, value) {
        if (key is String && value is String &&
            (key == 'font' || key == 'color' || key == 'display' || key == 'size')) {
          changed[key] = value;
        }
      });
      await _dispatchSubtitleQuickPreferences(changed);
    } catch (error) {
      debugPrint('Could not sync subtitle quick settings: $error');
    }
  }

  Future<void> _consumeScreenshot() async {
    if (!_nativeHostReady || _pendingScreenshotPath == null) return;
    final path = _pendingScreenshotPath!;
    _pendingScreenshotPath = null;
    try {
      final selected = await _attachmentOcrChannel
          .invokeMethod<Map<Object?, Object?>>(
            'recognizeText',
            <String, Object?>{'path': path},
          );
      if (selected == null) throw const FormatException('截图识别无结果');
      final payload = Map<String, Object?>.from(selected);
      payload['name'] = '当前屏幕截图';
      final literal = jsonEncode(jsonEncode(payload));
      await _controller.runJavaScript('''
        window.dispatchEvent(new CustomEvent("miyin:open-screen", {detail:{screen:"home"}}));
        window.dispatchEvent(new CustomEvent("miyin:screenshot-ready", {detail:JSON.parse($literal)}));
      ''');
    } catch (error) {
      debugPrint('Screenshot translation could not start: $error');
      final literal = jsonEncode(error.toString());
      await _controller.runJavaScript('''
        window.dispatchEvent(new CustomEvent("miyin:open-screen", {detail:{screen:"home"}}));
        window.dispatchEvent(new CustomEvent("miyin:screenshot-error", {detail:$literal}));
      ''');
    } finally {
      try {
        await File(path).delete();
      } catch (_) {
        /* temporary frame */
      }
    }
  }

  Future<void> _showScreenshotError(String message) async {
    if (!_nativeHostReady) return;
    final literal = jsonEncode(message);
    await _controller.runJavaScript('''
      window.dispatchEvent(new CustomEvent("miyin:open-screen", {detail:{screen:"home"}}));
      window.dispatchEvent(new CustomEvent("miyin:screenshot-error", {detail:$literal}));
    ''');
  }

  Future<void> _consumeFloatingScreen() async {
    if (!_nativeHostReady) return;
    try {
      final screen = await _floatingChannel.invokeMethod<String>(
        'initialScreen',
      );
      if (screen == 'video' ||
          screen == 'settings' ||
          screen == 'home' ||
          screen == 'floating-settings') {
        _pendingFloatingScreen = screen;
      }
      await _openPendingFloatingScreen();
      final screenshot = await _floatingChannel.invokeMethod<String>(
        'initialScreenshot',
      );
      if (screenshot != null) {
        _pendingScreenshotPath = screenshot;
        await _consumeScreenshot();
      }
      final screenshotError = await _floatingChannel.invokeMethod<String>(
        'initialScreenshotError',
      );
      if (screenshotError != null) await _showScreenshotError(screenshotError);
    } catch (error) {
      debugPrint('Could not route floating shortcut: $error');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appVisible = true;
      unawaited(_syncNativeRefreshState());
      unawaited(_syncSubtitleQuickPreferences());
      unawaited(_consumeFloatingScreen());
      unawaited(_emitLiveEvent('snapshot'));
      if (_livePendingEnd) unawaited(_emitLiveEvent('ended'));
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _appVisible = false;
      if (state == AppLifecycleState.paused && _nativeHostReady) {
        unawaited(_controller.runJavaScript(
          'window.dispatchEvent(new Event("miyin:app-paused"));',
        ).catchError((Object _) {}));
      }
      if (!(_liveActive && (_liveMode == 'mic' || _liveMode == 'conference'))) {
        unawaited(MiyinOfflineSpeechRecognizer.instance.cancelActive());
      }
      _refreshCoordinator.returnToSystemPolicy();
    }
  }

  Future<void> _handleSystemBack() async {
    if (!_nativeHostReady) {
      await SystemNavigator.pop();
      return;
    }
    try {
      final result = await _controller.runJavaScriptReturningResult(
        'window.MiyinV6Navigation?.handleSystemBack() === true',
      );
      if (result != true && result.toString() != 'true') {
        await SystemNavigator.pop();
      }
    } on PlatformException catch (error) {
      debugPrint(
        'Could not route Android back to the active page: ${error.message}',
      );
      await SystemNavigator.pop();
    }
  }

  Future<void> _syncNativeRefreshState() async {
    if (!_nativeHostReady) return;
    try {
      await _controller.runJavaScript(
        'window.dispatchEvent(new Event("miyin:refresh-state-sync")); window.dispatchEvent(new Event("miyin:app-resumed"));',
      );
    } on PlatformException catch (error) {
      debugPrint('Could not sync native refresh state: ${error.message}');
    }
  }

  @override
  void dispose() {
    unawaited(_chat.close());
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_stopLiveServices());
    _floatingChannel.setMethodCallHandler(null);
    _subtitleChannel.setMethodCallHandler(null);
    _voiceEvents?.cancel();
    _playbackEvents?.cancel();
    _offlineVoiceEvents?.cancel();
    _multilingualModelEvents?.cancel();
    unawaited(MiyinOfflineSpeechRecognizer.instance.dispose());
    unawaited(MiyinOfflineSpeechSynthesizer.instance.dispose());
    _refreshCoordinator.dispose();
    final pendingRouter = _rpcRouter;
    if (pendingRouter != null) unawaited(_closeRouter(pendingRouter));
    super.dispose();
  }

  Future<void> _stopLiveServices() async {
    _liveActive = false;
    _stopPlaybackPreview();
    _micGeneration++;
    try {
      await _playbackChannel.invokeMethod<void>('stopCapture');
    } catch (_) {
      /* not active */
    }
    try {
      await _microphoneSessionChannel.invokeMethod<void>('stop');
    } catch (_) {
      /* not active */
    }
    try {
      await _subtitleChannel.invokeMethod<void>('stop');
    } catch (_) {
      /* not active */
    }
  }

  Future<void> _closeRouter(Future<TranslationRpcRouter> pendingRouter) async {
    try {
      await (await pendingRouter).close();
    } catch (error) {
      debugPrint('Could not close the local translation database: $error');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigatorKey,
    title: '觅音',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: false,
      scaffoldBackgroundColor: Colors.white,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF14B8A6),
        primary: const Color(0xFF0F766E),
      ),
    ),
    home: PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_handleSystemBack());
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              WebViewWidget(controller: _controller),
              if (_isLoading && _loadError == null)
                const ColoredBox(
                  color: Colors.white,
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF14B8A6),
                      ),
                    ),
                  ),
                ),
              if (_loadError != null)
                ColoredBox(
                  color: Colors.white,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            size: 32,
                            color: Color(0xFF0F766E),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '觅音界面暂时无法打开',
                            style: TextStyle(
                              color: Color(0xFF134E4A),
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _loadError!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFF0D9488),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 16),
                          OutlinedButton.icon(
                            onPressed: () => _controller.reload(),
                            icon: const Icon(Icons.refresh_rounded),
                            label: const Text('重新加载'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
