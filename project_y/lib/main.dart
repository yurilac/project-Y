import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:project_y/dualsense_driver.dart';
import 'dart:async';

// 全局主题控制器
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

// ==================== 全局设备状态控制器 (解决状态丢失、后台与提醒逻辑) ====================
class DeviceMonitorController extends ChangeNotifier {
  final _driver = DualSenseDriver();
  Timer? _pollingTimer;

  // 1. 设置状态
  bool autoConnect = true;
  bool backgroundMonitor = false;
  bool lowBatteryAlert = true;

  // 2. 设备状态
  bool isConnected = false;
  int batteryLevel = 0;
  bool isCharging = false;
  
  bool _hasAlertedLowBattery = false;

  // UI 注册的回调，用于弹出通知提醒
  void Function(String message)? onShowAlert;

  // 更新设置开关
  void updateSettings({bool? auto, bool? background, bool? lowBattery}) {
    if (auto != null) autoConnect = auto;
    if (background != null) backgroundMonitor = background;
    if (lowBattery != null) lowBatteryAlert = lowBattery;
    notifyListeners();
  }

  // 连接并启动监测
  Future<void> connectAndMonitor() async {
    await _fetchData();
    if (isConnected) {
      _startTimer();
    } else {
      onShowAlert?.call('未发现 DualSense 手柄，请确认蓝牙已连接。');
    }
  }

  // 主动断开
  void disconnect() {
    _stopTimer();
    isConnected = false;
    batteryLevel = 0;
    isCharging = false;
    _hasAlertedLowBattery = false;
    notifyListeners();
  }

  void _startTimer() {
    _pollingTimer?.cancel();
    // (3) 一分钟刷新一次状态
    _pollingTimer = Timer.periodic(const Duration(minutes: 1), (_) => _fetchData());
  }

  void _stopTimer() {
    _pollingTimer?.cancel();
  }

  // 核心拉取逻辑
  Future<void> _fetchData() async {
    final result = _driver.getBatteryStatus();
    final wasConnected = isConnected;
    isConnected = result.isConnected;

    if (isConnected) {
      batteryLevel = result.batteryLevel;
      isCharging = result.isCharging;

      // (2) 低电量通知提醒 (低于 20% 且没在充电时提醒一次)
      if (lowBatteryAlert && batteryLevel <= 20 && !isCharging) {
        if (!_hasAlertedLowBattery) {
          _hasAlertedLowBattery = true;
          onShowAlert?.call('⚠️ 提醒：DualSense 手柄电量极低 ($batteryLevel%)，请及时充电！');
        }
      } else {
        _hasAlertedLowBattery = false; // 电量恢复或处于充电状态，重置通知锁
      }
    } else {
      _hasAlertedLowBattery = false;
      if (wasConnected) {
        onShowAlert?.call('DualSense 手柄已断开连接。');
        _stopTimer(); // 断开后停止轮询
      }
    }
    notifyListeners();
  }

  // (2) 处理应用生命周期（后台状态监测）
  void handleLifecycleChange(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // 如果未开启后台监测，进入后台时暂停定时器
      if (!backgroundMonitor) {
        _stopTimer();
      }
    } else if (state == AppLifecycleState.resumed) {
      // 回到前台，如果处于连接状态且定时器没在跑，恢复一分钟轮询
      if (isConnected && (_pollingTimer == null || !_pollingTimer!.isActive)) {
        _startTimer();
        _fetchData();
      }
    }
  }
}

// 单例全局实例
final globalMonitor = DeviceMonitorController();

// ===================================================================================

void main() {
  runApp(const DeviceMonitorApp());
}

class DeviceMonitorApp extends StatelessWidget {
  const DeviceMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, ThemeMode currentMode, __) {
        return MaterialApp(
          title: '跨平台演示 Demo',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent, brightness: Brightness.light),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent, brightness: Brightness.dark),
            useMaterial3: true,
          ),
          themeMode: currentMode,
          home: const MainNavigationScreen(),
        );
      },
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

// 混入 WidgetsBindingObserver 用于监听应用生命周期
class _MainNavigationScreenState extends State<MainNavigationScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;

  final List<Widget> _pages = const [
    MockSwitchesPage(),
    InteractionPage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 注册生命周期监听
    
    // 绑定全局提醒的 UI 呈现 (SnackBar)
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 移除监听
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 将生命周期变化传递给控制器处理
    globalMonitor.handleLifecycleChange(state);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备控制器 Demo'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(themeNotifier.value == ThemeMode.light ? Icons.dark_mode : Icons.light_mode),
            onPressed: () {
              themeNotifier.value = themeNotifier.value == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
            },
            tooltip: '切换主题',
          )
        ],
      ),
      // (1) 使用 IndexedStack 替代 AnimatedSwitcher，这样无论怎么切 Tab，内部滚动高度和局部状态都原封不动
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (int index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.toggle_on_outlined), selectedIcon: Icon(Icons.toggle_on), label: '设置与开关'),
          NavigationDestination(icon: Icon(Icons.gamepad_outlined), selectedIcon: Icon(Icons.gamepad), label: '外设交互'),
        ],
      ),
    );
  }
}

// ==================== 页面1：开关演示页 (重构为 Stateless 并监听全局) ====================
class MockSwitchesPage extends StatelessWidget {
  const MockSwitchesPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: globalMonitor,
      builder: (context, child) {
        return ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
              child: Text('连接首选项', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            Card(
              elevation: 0,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('蓝牙自动连接'),
                    subtitle: const Text('启动时自动寻找并配对已知设备'),
                    value: globalMonitor.autoConnect,
                    onChanged: (bool value) => globalMonitor.updateSettings(auto: value),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    title: const Text('后台状态监测'),
                    subtitle: const Text('应用最小化时持续获取信息'),
                    value: globalMonitor.backgroundMonitor,
                    onChanged: (bool value) => globalMonitor.updateSettings(background: value),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    title: const Text('低电量通知提醒'),
                    subtitle: const Text('当设备电量低于 20% 时弹出系统通知'),
                    value: globalMonitor.lowBatteryAlert,
                    onChanged: (bool value) => globalMonitor.updateSettings(lowBattery: value),
                  ),
                ],
              ),
            ),
          ],
        );
      }
    );
  }
}

// ==================== 页面2：交互演示页 (重构为 Stateless 并监听全局) ====================
class InteractionPage extends StatelessWidget {
  const InteractionPage({super.key});

  Color _getBatteryColor(int level) {
    if (level > 50) return Colors.greenAccent;
    if (level > 20) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: globalMonitor,
      builder: (context, child) {
        final isConnected = globalMonitor.isConnected;
        final batteryLevel = globalMonitor.batteryLevel;
        final isCharging = globalMonitor.isCharging;

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 状态卡片
              Container(
                padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isConnected
                        ? [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.secondary]
                        : [Colors.grey.shade700, Colors.grey.shade800],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 10,
                      offset: const Offset(0, 5),
                    )
                  ],
                ),
                child: Column(
                  children: [
                    if (!isConnected) ...[
                      const Icon(Icons.gamepad, size: 64, color: Colors.white54),
                      const SizedBox(height: 16),
                      const Text('DualSense 5 未连接', style: TextStyle(fontSize: 18, color: Colors.white)),
                    ] else ...[
                      // 环形电量指示器
                      SizedBox(
                        width: 120,
                        height: 120,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CircularProgressIndicator(
                              value: batteryLevel / 100,
                              strokeWidth: 12,
                              backgroundColor: Colors.white.withOpacity(0.2),
                              valueColor: AlwaysStoppedAnimation<Color>(_getBatteryColor(batteryLevel)),
                              strokeCap: StrokeCap.round,
                            ),
                            Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isCharging ? Icons.bolt : Icons.battery_std,
                                    color: Colors.white,
                                    size: 28,
                                  ),
                                  Text(
                                    '$batteryLevel%',
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text('DualSense 5 已连接 (Bluetooth)', 
                        style: TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.w500)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 40),

              // 操作按钮
              FilledButton.icon(
                onPressed: isConnected ? globalMonitor.disconnect : globalMonitor.connectAndMonitor,
                icon: Icon(isConnected ? Icons.bluetooth_disabled : Icons.bluetooth_connected),
                label: Text(isConnected ? '断开设备监测' : '连接并读取电量'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  backgroundColor: isConnected ? Colors.red.shade400 : null,
                ),
              ),
            ],
          ),
        );
      }
    );
  }
}