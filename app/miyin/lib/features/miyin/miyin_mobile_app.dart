import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

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

class _MiyinMobileAppState extends State<MiyinMobileApp> {
  late final WebViewController _controller;
  var _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _isLoading = true;
                _loadError = null;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
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
    unawaited(_controller.loadFlutterAsset('assets/miyin_v5/index.html'));
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
    home: Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
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
  );
}
