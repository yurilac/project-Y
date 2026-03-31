import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

// 新增：INI 配置服务
import 'package:project_y/config_service.dart';

// 引入四个设备的驱动
import 'package:project_y/dareu_driver.dart';
import 'package:project_y/dualsense_driver.dart';
import 'package:project_y/inzone_h5_driver.dart';
import 'package:project_y/logitech_driver.dart';

// ==================== 通用设备数据模型 ====================
class DeviceData {
  final String name;
  final int batteryLevel;
  final bool isCharging;
  final bool isConnected;
  final IconData icon;

  DeviceData({
    required this.name,
    required this.icon,
    this.batteryLevel = 0,
    this.isCharging = false,
    this.isConnected = false,
  });

  DeviceData copyWith({int? batteryLevel, bool? isCharging, bool? isConnected}) {
    return DeviceData(
      name: name,
      icon: icon,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      isCharging: isCharging ?? this.isCharging,
      isConnected: isConnected ?? this.isConnected,
    );
  }
}

// ==================== 主题配置 ====================
enum AppThemeSeed {
  sakuraPink,
  grassGreen,
  oceanBlue,
  vitalityYellow,
  mikuGreen,
}

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);
final ValueNotifier<AppThemeSeed> seedNotifier = ValueNotifier(AppThemeSeed.oceanBlue);

Color _seedToColor(AppThemeSeed seed) {
  switch (seed) {
    case AppThemeSeed.sakuraPink:
      return const Color(0xFFFF8FB1);
    case AppThemeSeed.grassGreen:
      return const Color(0xFF7BC47F);
    case AppThemeSeed.oceanBlue:
      return const Color(0xFF2F80ED);
    case AppThemeSeed.vitalityYellow:
      return const Color(0xFFF9C80E);
    case AppThemeSeed.mikuGreen:
      return const Color(0xFF39C5BB);
  }
}

String _seedLabel(AppThemeSeed seed) {
  switch (seed) {
    case AppThemeSeed.sakuraPink:
      return '樱花粉';
    case AppThemeSeed.grassGreen:
      return '浅草绿';
    case AppThemeSeed.oceanBlue:
      return '海洋蓝';
    case AppThemeSeed.vitalityYellow:
      return '活力黄';
    case AppThemeSeed.mikuGreen:
      return '初音绿';
  }
}

String _themeModeLabel(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.system:
      return '跟随系统';
    case ThemeMode.light:
      return '浅色';
    case ThemeMode.dark:
      return '深色';
  }
}

String _themeModeToRaw(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.dark:
      return 'dark';
    case ThemeMode.system:
      return 'system';
  }
}

String _seedToRaw(AppThemeSeed seed) {
  switch (seed) {
    case AppThemeSeed.sakuraPink:
      return 'sakuraPink';
    case AppThemeSeed.grassGreen:
      return 'grassGreen';
    case AppThemeSeed.oceanBlue:
      return 'oceanBlue';
    case AppThemeSeed.vitalityYellow:
      return 'vitalityYellow';
    case AppThemeSeed.mikuGreen:
      return 'mikuGreen';
  }
}

ThemeMode _rawToThemeMode(String raw) {
  switch (raw) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

AppThemeSeed _rawToSeed(String raw) {
  switch (raw) {
    case 'sakuraPink':
      return AppThemeSeed.sakuraPink;
    case 'grassGreen':
      return AppThemeSeed.grassGreen;
    case 'vitalityYellow':
      return AppThemeSeed.vitalityYellow;
    case 'mikuGreen':
      return AppThemeSeed.mikuGreen;
    default:
      return AppThemeSeed.oceanBlue;
  }
}

Future<void> _saveAllToIni() async {
  final data = AppConfigData(
    themeMode: _themeModeToRaw(themeNotifier.value),
    themeSeed: _seedToRaw(seedNotifier.value),
    launchAtStartup: globalMonitor.launchAtStartup,
    backgroundMonitor: globalMonitor.backgroundMonitor,
    lowBatteryAlert: globalMonitor.lowBatteryAlert,
  );
  await ConfigService.save(data);
}

// ==================== Windows 开机自启服务 ====================
class WindowsStartupService {
  static const String _appName = 'ProjectYDeviceMonitor';

  static Future<bool> setLaunchAtStartup(bool enabled) async {
    if (!Platform.isWindows) return false;
    final exePath = Platform.resolvedExecutable;
    final quoted = '"$exePath"';

    final args = enabled
        ? ['add', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run', '/v', _appName, '/t', 'REG_SZ', '/d', quoted, '/f']
        : ['delete', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run', '/v', _appName, '/f'];

    final result = await Process.run('reg', args, runInShell: true);
    return result.exitCode == 0;
  }

  static Future<bool> isLaunchAtStartupEnabled() async {
    if (!Platform.isWindows) return false;
    final result = await Process.run(
      'reg',
      ['query', r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run', '/v', _appName],
      runInShell: true,
    );
    return result.exitCode == 0;
  }
}

// ==================== 托盘 + 通知 ====================
class DesktopIntegrationService {
  final SystemTray _systemTray = SystemTray();
  final Menu _menu = Menu();
  bool _inited = false;

  VoidCallback? onShowWindow;
  VoidCallback? onOpenSettings;
  VoidCallback? onExitApp;

  Future<void> init() async {
    if (!Platform.isWindows || _inited) return;

    await localNotifier.setup(
      appName: '外设电量',
      shortcutPolicy: ShortcutPolicy.requireCreate,
    );

    const iconPath = 'assets/app_icon.ico';
    await _systemTray.initSystemTray(
      title: '外设电量',
      iconPath: iconPath,
      toolTip: '外设电量监控',
    );

    await _menu.buildFrom([
      MenuItemLabel(label: '打开主界面', onClicked: (_) => onShowWindow?.call()),
      MenuItemLabel(label: '设置', onClicked: (_) => onOpenSettings?.call()),
      MenuSeparator(),
      MenuItemLabel(label: '退出', onClicked: (_) => onExitApp?.call()),
    ]);

    await _systemTray.setContextMenu(_menu);

    _systemTray.registerSystemTrayEventHandler((eventName) async {
      if (eventName == kSystemTrayEventRightClick) {
        await _systemTray.popUpContextMenu();
      } else if (eventName == kSystemTrayEventClick) {
        onShowWindow?.call();
      }
    });

    _inited = true;
  }

  Future<void> showLowBatteryNotification({
    required String deviceName,
    required int battery,
  }) async {
    if (!Platform.isWindows) return;
    final n = LocalNotification(
      title: '低电量提醒',
      body: '$deviceName 电量仅剩 $battery%，请及时充电。',
    );
    await n.show();
  }
}

final desktopService = DesktopIntegrationService();

// ==================== 全局设备状态控制器 ====================
class DeviceMonitorController extends ChangeNotifier {
  final _dsDriver = DualSenseDriver();
  final _logiDriver = LogitechDriver();
  final _dareuDriver = DareuDriver();
  final _inzoneH5Driver = InzoneH5Driver();

  Timer? _pollingTimer;
  Timer? _startupRetryTimer;

  bool launchAtStartup = false;
  bool backgroundMonitor = true;
  bool lowBatteryAlert = true;

  List<DeviceData> devices = [
    DeviceData(name: 'PS5 DualSense', icon: Icons.gamepad),
    DeviceData(name: '罗技 GPW 2代', icon: Icons.mouse),
    DeviceData(name: '达尔优 EK87 PRO', icon: Icons.keyboard),
    DeviceData(name: 'Sony INZONE H5', icon: Icons.headphones),
  ];

  final Map<String, bool> _hasAlertedLowBattery = {};
  void Function(String message)? onShowAlert;

  Future<void> updateSettings({bool? startup, bool? background, bool? lowBattery}) async {
    if (startup != null) launchAtStartup = startup;
    if (background != null) backgroundMonitor = background;
    if (lowBattery != null) lowBatteryAlert = lowBattery;
    notifyListeners();
    await _saveAllToIni(); // INI 持久化
  }

  Future<void> connectAndMonitor() async {
    await _fetchData();
    _startTimer();
    // If some devices were not found on the initial scan, schedule a retry after
    // a short delay. This handles the case where the Windows HID subsystem has
    // not yet fully initialized when the app auto-starts at boot.
    if (devices.any((d) => !d.isConnected)) {
      _startupRetryTimer = Timer(const Duration(seconds: 5), () async {
        if (_pollingTimer != null && _pollingTimer!.isActive) {
          await _fetchData();
        }
      });
    }
  }

  void disconnect() {
    _startupRetryTimer?.cancel();
    _stopTimer();
    devices = devices
        .map((d) => d.copyWith(isConnected: false, batteryLevel: 0, isCharging: false))
        .toList();
    _hasAlertedLowBattery.clear();
    notifyListeners();
  }

  void _startTimer() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(minutes: 1), (_) => _fetchData());
  }

  void _stopTimer() {
    _pollingTimer?.cancel();
  }

  Future<void> _fetchData() async {
    final dsStatus = _dsDriver.getBatteryStatus();
    final logiStatus = _logiDriver.getBatteryStatus();
    final dareuStatus = _dareuDriver.getBatteryStatus();
    final inzoneH5Status = _inzoneH5Driver.getBatteryStatus();

    devices[0] = devices[0].copyWith(
      isConnected: dsStatus.isConnected,
      batteryLevel: dsStatus.batteryLevel,
      isCharging: dsStatus.isCharging,
    );
    devices[1] = devices[1].copyWith(
      isConnected: logiStatus.isConnected,
      batteryLevel: logiStatus.batteryLevel,
      isCharging: logiStatus.isCharging,
    );
    devices[2] = devices[2].copyWith(
      isConnected: dareuStatus.isConnected,
      batteryLevel: dareuStatus.batteryLevel,
      isCharging: dareuStatus.isCharging,
    );
    devices[3] = devices[3].copyWith(
      isConnected: inzoneH5Status.isConnected,
      batteryLevel: inzoneH5Status.batteryLevel,
      isCharging: inzoneH5Status.isCharging,
    );

    for (var dev in devices) {
      if (dev.isConnected) {
        if (lowBatteryAlert && dev.batteryLevel <= 20 && !dev.isCharging) {
          if (!(_hasAlertedLowBattery[dev.name] ?? false)) {
            _hasAlertedLowBattery[dev.name] = true;
            final msg = '⚠️ 提醒：${dev.name} 电量低 (${dev.batteryLevel}%)，请及时充电！';
            onShowAlert?.call(msg);
            await desktopService.showLowBatteryNotification(
              deviceName: dev.name,
              battery: dev.batteryLevel,
            );
          }
        } else {
          _hasAlertedLowBattery[dev.name] = false;
        }
      }
    }
    notifyListeners();
  }

  void handleLifecycleChange(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (!backgroundMonitor) _stopTimer();
    } else if (state == AppLifecycleState.resumed) {
      if (_pollingTimer == null || !_pollingTimer!.isActive) {
        _startTimer();
      }
      // Always fetch immediately on resume so the UI shows current device
      // status as soon as the window is visible, rather than waiting up to
      // one minute for the next periodic timer tick.
      _fetchData();
    }
  }
}

final globalMonitor = DeviceMonitorController();

// ==================== 星星背景层 ====================
class StarPatternPainter extends CustomPainter {
  final Color starColor;
  StarPatternPainter({required this.starColor});

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 28.0;
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: '✦',
        style: TextStyle(
          color: starColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    )..layout();

    for (double y = 8; y < size.height + spacing; y += spacing) {
      for (double x = 8; x < size.width + spacing; x += spacing) {
        final offsetX = ((y / spacing).floor().isEven) ? 0.0 : spacing / 2;
        final dx = x + offsetX;
        final jitter = math.sin((dx + y) * 0.06) * 2.0;
        textPainter.paint(canvas, Offset(dx, y + jitter));
      }
    }
  }

  @override
  bool shouldRepaint(covariant StarPatternPainter oldDelegate) {
    return oldDelegate.starColor != starColor;
  }
}

// ==================== 玻璃组件 ====================
class GlassCard extends StatelessWidget {
  final Widget child;
  final bool isDark;
  final Color seedColor;
  final EdgeInsetsGeometry? padding;
  const GlassCard({
    super.key,
    required this.child,
    required this.isDark,
    required this.seedColor,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final tint = isDark ? Colors.white.withOpacity(0.07) : Colors.white.withOpacity(0.23);
    final border = isDark ? Colors.white24 : Colors.black12;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    seedColor.withOpacity(isDark ? 0.09 : 0.14),
                    seedColor.withOpacity(isDark ? 0.03 : 0.05),
                  ],
                ),
              ),
            ),
          ),
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                color: tint,
                border: Border.all(color: border, width: 0.6),
                borderRadius: BorderRadius.circular(16),
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class GlassBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget child;
  final double height;
  final bool isDark;
  final Color seedColor;
  const GlassBar({
    super.key,
    required this.child,
    required this.height,
    required this.isDark,
    required this.seedColor,
  });

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final tint = isDark ? Colors.white.withOpacity(0.07) : Colors.white.withOpacity(0.46);
    final border = isDark ? Colors.white24 : Colors.black12;

    return SizedBox(
      height: height,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      seedColor.withOpacity(isDark ? 0.10 : 0.16),
                      seedColor.withOpacity(isDark ? 0.03 : 0.06),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  decoration: BoxDecoration(
                    color: tint,
                    border: Border(bottom: BorderSide(color: border, width: 0.6)),
                  ),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GlassBottomBar extends StatelessWidget {
  final Widget child;
  final bool isDark;
  final Color seedColor;
  const GlassBottomBar({
    super.key,
    required this.child,
    required this.isDark,
    required this.seedColor,
  });

  @override
  Widget build(BuildContext context) {
    final tint = isDark ? Colors.white.withOpacity(0.07) : Colors.white.withOpacity(0.46);
    final border = isDark ? Colors.white24 : Colors.black12;

    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    seedColor.withOpacity(isDark ? 0.12 : 0.20),
                    seedColor.withOpacity(isDark ? 0.04 : 0.08),
                  ],
                ),
              ),
            ),
          ),
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              decoration: BoxDecoration(
                color: tint,
                border: Border(top: BorderSide(color: border, width: 0.6)),
              ),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

// ===================================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 INI
  await ConfigService.init();
  final ini = await ConfigService.load();

  // 应用主题设置（来自 INI）
  themeNotifier.value = _rawToThemeMode(ini.themeMode);
  seedNotifier.value = _rawToSeed(ini.themeSeed);

  // 应用全局设置（来自 INI）
  globalMonitor.launchAtStartup = ini.launchAtStartup;
  globalMonitor.backgroundMonitor = ini.backgroundMonitor;
  globalMonitor.lowBatteryAlert = ini.lowBatteryAlert;

  // 启动即自动监测
  unawaited(globalMonitor.connectAndMonitor());

  // 校准开机启动开关（Windows）
  if (Platform.isWindows) {
    globalMonitor.launchAtStartup = await WindowsStartupService.isLaunchAtStartupEnabled();
    await _saveAllToIni(); // 写回 ini 保持一致
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(520, 880),
      center: true,
      title: '外设电量',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const DeviceMonitorApp());
}

class DeviceMonitorApp extends StatelessWidget {
  const DeviceMonitorApp({super.key});

  TextStyle? _plusOne(TextStyle? style) {
    if (style == null) return null;
    final fs = style.fontSize ?? 14.0;
    return style.copyWith(fontSize: fs + 1.0);
  }

  TextTheme _textThemePlusOne(TextTheme t) {
    return TextTheme(
      displayLarge: _plusOne(t.displayLarge),
      displayMedium: _plusOne(t.displayMedium),
      displaySmall: _plusOne(t.displaySmall),
      headlineLarge: _plusOne(t.headlineLarge),
      headlineMedium: _plusOne(t.headlineMedium),
      headlineSmall: _plusOne(t.headlineSmall),
      titleLarge: _plusOne(t.titleLarge),
      titleMedium: _plusOne(t.titleMedium),
      titleSmall: _plusOne(t.titleSmall),
      bodyLarge: _plusOne(t.bodyLarge),
      bodyMedium: _plusOne(t.bodyMedium),
      bodySmall: _plusOne(t.bodySmall),
      labelLarge: _plusOne(t.labelLarge),
      labelMedium: _plusOne(t.labelMedium),
      labelSmall: _plusOne(t.labelSmall),
    );
  }

  ThemeData _withFontSizeDelta(ThemeData base) {
    return base.copyWith(
      textTheme: _textThemePlusOne(base.textTheme),
      primaryTextTheme: _textThemePlusOne(base.primaryTextTheme),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, currentMode, __) {
        return ValueListenableBuilder<AppThemeSeed>(
          valueListenable: seedNotifier,
          builder: (_, currentSeed, __) {
            final color = _seedToColor(currentSeed);

            final light = ThemeData(
              fontFamily: 'JingNanMaiYuanTi',
              useMaterial3: true,
              brightness: Brightness.light,
              scaffoldBackgroundColor: Colors.transparent,
              colorScheme: ColorScheme.light(
                primary: color,
                secondary: color,
                surface: Colors.white,
                onSurface: Colors.black87,
                onPrimary: Colors.white,
              ),
              appBarTheme: const AppBarTheme(
                backgroundColor: Colors.transparent,
                foregroundColor: Colors.black87,
                elevation: 0,
                scrolledUnderElevation: 0,
              ),
              cardTheme: const CardThemeData(
                color: Colors.white,
                surfaceTintColor: Colors.transparent,
              ),
            );

            final dark = ThemeData(
              fontFamily: 'JingNanMaiYuanTi',
              useMaterial3: true,
              brightness: Brightness.dark,
              scaffoldBackgroundColor: Colors.transparent,
              colorScheme: ColorScheme.dark(
                primary: color,
                secondary: color,
                surface: const Color(0xFF17181A),
                onSurface: Colors.white,
                onPrimary: Colors.black,
              ),
              appBarTheme: const AppBarTheme(
                backgroundColor: Colors.transparent,
                foregroundColor: Colors.white,
                elevation: 0,
                scrolledUnderElevation: 0,
              ),
              cardTheme: const CardThemeData(
                color: Color(0xFF17181A),
                surfaceTintColor: Colors.transparent,
              ),
            );

            return MaterialApp(
              title: '外设电量',
              debugShowCheckedModeBanner: false,
              theme: _withFontSizeDelta(light),
              darkTheme: _withFontSizeDelta(dark),
              themeMode: currentMode,
              home: const MainNavigationScreen(),
            );
          },
        );
      },
    );
  }
}

// ==================== 主页面 ====================
class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});
  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> with WidgetsBindingObserver, WindowListener {
  int _currentIndex = 0;
  bool _isExiting = false;
  final List<Widget> _pages = const [InteractionPage(), MockSwitchesPage()];

  String _appTitle = '｡.ﾟ+:ヾ(*･ω･)ｼ.:ﾟ+｡';
  bool _isEditingTitle = false;
  late final TextEditingController _titleController;
  final FocusNode _titleFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _titleController = TextEditingController(text: _appTitle);

    globalMonitor.onShowAlert = (msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            behavior: SnackBarBehavior.floating,
            backgroundColor: msg.contains('⚠️') ? Colors.redAccent : null,
          ),
        );
      }
    };

    _initDesktopIntegration();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _titleController.dispose();
    _titleFocusNode.dispose();
    if (Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  void _startEditTitle() {
    setState(() {
      _isEditingTitle = true;
      _titleController.text = _appTitle;
    });
    Future.microtask(() {
      _titleFocusNode.requestFocus();
      _titleController.selection =
          TextSelection(baseOffset: 0, extentOffset: _titleController.text.length);
    });
  }

  void _finishEditTitle({bool save = true}) {
    if (save) {
      final newTitle = _titleController.text.trim();
      if (newTitle.isNotEmpty) _appTitle = newTitle;
    }
    setState(() => _isEditingTitle = false);
  }

  Future<void> _initDesktopIntegration() async {
    if (!Platform.isWindows) return;
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);

    await desktopService.init();
    desktopService.onShowWindow = () async {
      setState(() => _currentIndex = 0);
      await windowManager.show();
      await windowManager.restore();
      await windowManager.focus();
    };
    desktopService.onOpenSettings = () async {
      setState(() => _currentIndex = 1);
      await windowManager.show();
      await windowManager.restore();
      await windowManager.focus();
    };
    desktopService.onExitApp = () async {
      if (_isExiting) return;
      _isExiting = true;
      globalMonitor.disconnect();
      if (Platform.isWindows) {
        await windowManager.setPreventClose(false);
      }
      exit(0);
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => globalMonitor.handleLifecycleChange(state);

  @override
  void onWindowClose() async {
    if (!Platform.isWindows) return;
    if (_isExiting) return;
    await windowManager.hide();
  }

  @override
  void onWindowMinimize() async {
    if (!Platform.isWindows) return;
    if (globalMonitor.backgroundMonitor) {
      await windowManager.hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final seed = Theme.of(context).colorScheme.primary;
    final baseColor = isDark ? const Color(0xFF0F0F10) : Colors.white;
    final starColor = isDark ? Colors.white.withOpacity(0.08) : Colors.black.withOpacity(0.14);

    final topBarHeight = (kToolbarHeight * 1.14) + MediaQuery.of(context).padding.top;

    return Scaffold(
      extendBody: true,
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: baseColor)),
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: StarPatternPainter(starColor: starColor)),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: topBarHeight),
            child: IndexedStack(index: _currentIndex, children: _pages),
          ),
        ],
      ),
      appBar: GlassBar(
        isDark: isDark,
        seedColor: seed,
        height: topBarHeight,
        child: AppBar(
          backgroundColor: Colors.transparent,
          toolbarHeight: kToolbarHeight * 1.14,
          automaticallyImplyLeading: false,
          titleSpacing: 0,
          title: Stack(
            alignment: Alignment.center,
            children: [
              Center(
                child: _isEditingTitle
                    ? SizedBox(
                        width: 320,
                        child: TextField(
                          controller: _titleController,
                          focusNode: _titleFocusNode,
                          autofocus: true,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            filled: true,
                            fillColor: isDark
                                ? Colors.white.withOpacity(0.10)
                                : Colors.black.withOpacity(0.05),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: Theme.of(context).colorScheme.primary.withOpacity(0.45),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: Theme.of(context).colorScheme.primary.withOpacity(0.35),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: Theme.of(context).colorScheme.primary,
                                width: 1.4,
                              ),
                            ),
                          ),
                          onSubmitted: (_) => _finishEditTitle(save: true),
                          onTapOutside: (_) => _finishEditTitle(save: true),
                        ),
                      )
                    : GestureDetector(
                        onTap: _startEditTitle,
                        child: Text(
                          _appTitle,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: IconButton(
                    tooltip: '主题设置',
                    icon: const Icon(Icons.palette_outlined),
                    onPressed: () => showModalBottomSheet(
                      context: context,
                      showDragHandle: true,
                      builder: (_) => const _ThemeSettingSheet(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: GlassBottomBar(
        isDark: isDark,
        seedColor: seed,
        child: NavigationBar(
          backgroundColor: Colors.transparent,
          selectedIndex: _currentIndex,
          onDestinationSelected: (int index) => setState(() => _currentIndex = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.hub_outlined),
              selectedIcon: Icon(Icons.hub),
              label: '设备状态',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '全局设置',
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeSettingSheet extends StatelessWidget {
  const _ThemeSettingSheet();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('主题模式', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeNotifier,
            builder: (_, mode, __) => Wrap(
              spacing: 8,
              children: ThemeMode.values.map((m) {
                return ChoiceChip(
                  label: Text(_themeModeLabel(m)),
                  selected: mode == m,
                  onSelected: (_) async {
                    themeNotifier.value = m;
                    await _saveAllToIni();
                  },
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 16),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('主题色', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<AppThemeSeed>(
            valueListenable: seedNotifier,
            builder: (_, seed, __) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: AppThemeSeed.values.map((s) {
                return ChoiceChip(
                  label: Text(_seedLabel(s)),
                  selected: seed == s,
                  avatar: CircleAvatar(backgroundColor: _seedToColor(s), radius: 8),
                  onSelected: (_) async {
                    seedNotifier.value = s;
                    await _saveAllToIni();
                  },
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 页面1：全局设置页 ====================
class MockSwitchesPage extends StatelessWidget {
  const MockSwitchesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final seed = Theme.of(context).colorScheme.primary;

    final inactiveThumb = isDark ? const Color(0xFF9AA1AA) : const Color(0xFFB7BDC6);
    final inactiveTrack = isDark ? const Color(0xFF4A5059) : const Color(0xFFD9DEE5);
    final dividerColor = isDark ? Colors.white.withOpacity(0.26) : Colors.black.withOpacity(0.24);

    Widget buildTile({
      required bool value,
      required String title,
      required String subtitle,
      required ValueChanged<bool> onChanged,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(subtitle, style: const TextStyle(fontSize: 15)),
          ),
          value: value,
          onChanged: onChanged,
          activeColor: primary,
          activeTrackColor: primary.withOpacity(0.42),
          inactiveThumbColor: inactiveThumb,
          inactiveTrackColor: inactiveTrack,
          splashRadius: 20,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          thumbIcon: WidgetStateProperty.resolveWith<Icon?>((states) {
            final selected = states.contains(WidgetState.selected);
            if (!selected) return null;
            return Icon(
              Icons.circle,
              size: 10,
              color: Colors.white.withOpacity(0.92),
              shadows: [
                Shadow(
                  color: primary.withOpacity(isDark ? 0.55 : 0.45),
                  blurRadius: 10,
                ),
              ],
            );
          }),
        ),
      );
    }

    return AnimatedBuilder(
      animation: globalMonitor,
      builder: (context, child) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 36),
          children: [
            GlassCard(
              isDark: isDark,
              seedColor: seed,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                children: [
                  buildTile(
                    value: globalMonitor.launchAtStartup,
                    title: '开机启动',
                    subtitle: '开机自动启动应用并开始监测',
                    onChanged: (v) async {
                      await globalMonitor.updateSettings(startup: v);

                      final ok = await WindowsStartupService.setLaunchAtStartup(v);
                      if (!ok && context.mounted) {
                        await globalMonitor.updateSettings(startup: !v);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('设置开机启动失败，请检查权限后重试'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      } else if (ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(v ? '已开启开机启动' : '已关闭开机启动'),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                    child: Divider(height: 1, color: dividerColor),
                  ),
                  buildTile(
                    value: globalMonitor.backgroundMonitor,
                    title: '后台状态监测',
                    subtitle: '应用最小化时持续获取信息（Windows托盘）',
                    onChanged: (v) async => globalMonitor.updateSettings(background: v),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                    child: Divider(height: 1, color: dividerColor),
                  ),
                  buildTile(
                    value: globalMonitor.lowBatteryAlert,
                    title: '低电量通知提醒',
                    subtitle: '设备低于 20% 发送提醒',
                    onChanged: (v) async => globalMonitor.updateSettings(lowBattery: v),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ==================== 页面2：设备监测列表页 ====================
class InteractionPage extends StatelessWidget {
  const InteractionPage({super.key});

  static const double _bottomBarReserve = kBottomNavigationBarHeight + 50;

  Color _getBatteryColor(int level) {
    if (level > 50) return Colors.greenAccent;
    if (level > 20) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final seed = Theme.of(context).colorScheme.primary;

    return AnimatedBuilder(
      animation: globalMonitor,
      builder: (context, child) {
        final isAnyConnected = globalMonitor.devices.any((d) => d.isConnected);

        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, _bottomBarReserve),
                itemCount: globalMonitor.devices.length,
                itemBuilder: (context, index) {
                  final dev = globalMonitor.devices[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: GlassCard(
                      isDark: isDark,
                      seedColor: seed,
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOut,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: dev.isConnected
                                  ? [
                                      BoxShadow(
                                        color: primary.withOpacity(isDark ? 0.30 : 0.22),
                                        blurRadius: 14,
                                        spreadRadius: 1.2,
                                      ),
                                    ]
                                  : const [],
                            ),
                            child: Icon(
                              dev.icon,
                              size: 48,
                              color: dev.isConnected ? primary : Colors.grey,
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  dev.name,
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  dev.isConnected ? '已连接' : '未发现设备',
                                  style: TextStyle(color: dev.isConnected ? Colors.green : Colors.grey),
                                ),
                              ],
                            ),
                          ),
                          if (dev.isConnected)
                            Column(
                              children: [
                                Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    CircularProgressIndicator(
                                      value: dev.batteryLevel / 100,
                                      backgroundColor: Colors.grey.shade300,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        _getBatteryColor(dev.batteryLevel),
                                      ),
                                    ),
                                    Icon(
                                      dev.isCharging ? Icons.bolt : Icons.battery_std,
                                      size: 16,
                                      color: _getBatteryColor(dev.batteryLevel),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${dev.batteryLevel}%',
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, _bottomBarReserve),
              child: DecoratedBox(
                decoration: isAnyConnected
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: primary.withOpacity(isDark ? 0.55 : 0.40),
                            blurRadius: 18,
                            spreadRadius: 1.6,
                          ),
                        ],
                      )
                    : const BoxDecoration(),
                child: FilledButton.icon(
                  onPressed: isAnyConnected ? globalMonitor.disconnect : globalMonitor.connectAndMonitor,
                  icon: Icon(isAnyConnected ? Icons.stop_circle : Icons.play_arrow),
                  label: Text(isAnyConnected ? '停止所有监测' : '一键扫描设备电量'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(double.infinity, 60),
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
