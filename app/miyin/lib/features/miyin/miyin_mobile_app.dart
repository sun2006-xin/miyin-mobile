import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/adaptive_refresh_coordinator.dart';
import '../../core/storage/translation_history_repository.dart';
import '../../core/translation/mlkit_translation_engine.dart';
import '../../core/translation/translation_service.dart';
import 'attachment_source_picker.dart';
import 'avatar_image_picker.dart';
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
  late final WebViewController _controller;
  late final AdaptiveRefreshCoordinator _refreshCoordinator;
  late final PlatformAttachmentSourcePicker _attachmentSourcePicker;
  late final PlatformAvatarImagePicker _avatarImagePicker;
  late final Future<PickedAttachmentSource?> _recoveredAttachment;
  var _isLoading = true;
  var _nativeHostReady = false;
  String? _loadError;
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
    _controller = WebViewController();
    unawaited(_configureWebView());
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
        onPageStarted: (_) {
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
      avatarImagePicker: _avatarImagePicker,
    );
  }

  Future<void> _handleNativeRequest(String rawMessage) async {
    Map<String, Object?> response;
    try {
      response = await (await _getRpcRouter()).handle(rawMessage);
    } catch (error) {
      response = {
        'version': 1,
        'id': _requestIdFrom(rawMessage),
        'ok': false,
        'error': {'code': 'native_unavailable', 'message': '本机翻译暂时不可用。'},
      };
      debugPrint('Miyin native translation request failed: $error');
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
            const syncVisibleHeight = () => {
              const height = Math.round(viewport?.height || window.innerHeight);
              if (height > 0) {
                root.style.setProperty("--miyin-visible-height", height + "px");
              }
            };
            syncVisibleHeight();
            window.addEventListener("resize", syncVisibleHeight, {passive: true});
            viewport?.addEventListener("resize", syncVisibleHeight, {passive: true});
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
          })();
        ''');
    } catch (error) {
      _nativeHostReady = false;
      debugPrint('Could not initialize native performance signals: $error');
    }
    if (_nativeHostReady) {
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncNativeRefreshState());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
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
        'window.dispatchEvent(new Event("miyin:refresh-state-sync"));',
      );
    } on PlatformException catch (error) {
      debugPrint('Could not sync native refresh state: ${error.message}');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshCoordinator.dispose();
    final pendingRouter = _rpcRouter;
    if (pendingRouter != null) unawaited(_closeRouter(pendingRouter));
    super.dispose();
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
