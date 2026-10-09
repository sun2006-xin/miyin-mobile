import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miyin_app/features/miyin/miyin_mobile_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MiyinMobileApp());
}
