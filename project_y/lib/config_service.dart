import 'dart:io';

import 'package:ini/ini.dart';
import 'package:path/path.dart' as p;

class AppConfigData {
  String themeMode; // system/light/dark
  String themeSeed; // sakuraPink/grassGreen/oceanBlue/vitalityYellow/mikuGreen

  bool launchAtStartup;
  bool backgroundMonitor;
  bool lowBatteryAlert;

  AppConfigData({
    this.themeMode = 'system',
    this.themeSeed = 'oceanBlue',
    this.launchAtStartup = false,
    this.backgroundMonitor = true,
    this.lowBatteryAlert = true,
  });
}

class ConfigService {
  static late final File _file;
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;

    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      _file = File('config.ini');
    } else {
      final dir = Directory(p.join(appData, 'ProjectY'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _file = File(p.join(dir.path, 'config.ini'));
    }

    if (!await _file.exists()) {
      await _file.writeAsString(_defaultIni());
    }

    _inited = true;
  }

  static String _defaultIni() {
    return '''
[theme]
mode=system
seed=oceanBlue

[settings]
launch_at_startup=false
background_monitor=true
low_battery_alert=true
''';
  }

  static Future<AppConfigData> load() async {
    await init();
    final text = await _file.readAsString();
    final ini = Config.fromString(text);

    return AppConfigData(
      themeMode: ini.get('theme', 'mode') ?? 'system',
      themeSeed: ini.get('theme', 'seed') ?? 'oceanBlue',
      launchAtStartup: (ini.get('settings', 'launch_at_startup') ?? 'false').toLowerCase() == 'true',
      backgroundMonitor: (ini.get('settings', 'background_monitor') ?? 'true').toLowerCase() == 'true',
      lowBatteryAlert: (ini.get('settings', 'low_battery_alert') ?? 'true').toLowerCase() == 'true',
    );
  }
static Future<void> save(AppConfigData data) async {
  await init();

  final ini = Config();
  ini.addSection('theme');
  ini.addSection('settings');

  ini.set('theme', 'mode', data.themeMode);
  ini.set('theme', 'seed', data.themeSeed);

  ini.set('settings', 'launch_at_startup', data.launchAtStartup.toString());
  ini.set('settings', 'background_monitor', data.backgroundMonitor.toString());
  ini.set('settings', 'low_battery_alert', data.lowBatteryAlert.toString());

  await _file.writeAsString(ini.toString());
}
}