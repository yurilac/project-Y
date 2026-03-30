import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';

// 引入三个设备的驱动
import 'package:project_y/dualsense_driver.dart';
import 'package:project_y/logitech_driver.dart';
import 'package:project_y/dareu_driver.dart';
import 'package:project_y/inzone_h5_driver.dart';


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

// 全局主题控制器
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

// ==================== 全局设备状态控制器 ====================
class DeviceMonitorController extends ChangeNotifier {
  final _dsDriver = DualSenseDriver();
  final _logiDriver = LogitechDriver();
  final _dareuDriver = DareuDriver();
  final _inzoneH5Driver = InzoneH5Driver();

  Timer? _pollingTimer;
  // 设置状态
  bool autoConnect = true;
  bool backgroundMonitor = false;
  bool lowBatteryAlert = true;

  // 设备列表状态
  List<DeviceData> devices = [
    DeviceData(name: 'PS5 DualSense', icon: Icons.gamepad),
    DeviceData(name: '罗技 GPW 2代', icon: Icons.mouse),
    DeviceData(name: '达尔优 EK87 PRO', icon: Icons.keyboard),
    DeviceData(name: 'Inzone H5', icon: Icons.headphones),
  ];

  final Map<String, bool> _hasAlertedLowBattery = {};
  void Function(String message)? onShowAlert;

  void updateSettings({bool? auto, bool? background, bool? lowBattery}) {
    if (auto != null) autoConnect = auto;
    if (background != null) backgroundMonitor = background;
    if (lowBattery != null) lowBatteryAlert = lowBattery;
    notifyListeners();
  }

  Future<void> connectAndMonitor() async {
    await _fetchData();
    _startTimer();
  }

  void disconnect() {
    _stopTimer();
    devices = devices.map((d) => d.copyWith(isConnected: false, batteryLevel: 0, isCharging: false)).toList();
    _hasAlertedLowBattery.clear();
    notifyListeners();
  }

  void _startTimer() {
    _pollingTimer?.cancel();
    // 1分钟刷新一次状态
    _pollingTimer = Timer.periodic(const Duration(minutes: 1), (_) => _fetchData());
  }

  void _stopTimer() {
    _pollingTimer?.cancel();
  }

  Future<void> _fetchData() async {
    // 分别拉取三个设备的状态
    final dsStatus = _dsDriver.getBatteryStatus();
    final logiStatus = _logiDriver.getBatteryStatus();
    final dareuStatus = _dareuDriver.getBatteryStatus();
    final inzoneH5Status = _inzoneH5Driver.getBatteryStatus();

    devices[0] = devices[0].copyWith(isConnected: dsStatus.isConnected, batteryLevel: dsStatus.batteryLevel, isCharging: dsStatus.isCharging);
    devices[1] = devices[1].copyWith(isConnected: logiStatus.isConnected, batteryLevel: logiStatus.batteryLevel, isCharging: logiStatus.isCharging);
    devices[2] = devices[2].copyWith(isConnected: dareuStatus.isConnected, batteryLevel: dareuStatus.batteryLevel, isCharging: dareuStatus.isCharging);
    devices[3] = devices[3].copyWith(isConnected: inzoneH5Status.isConnected, batteryLevel: inzoneH5Status.batteryLevel, isCharging: inzoneH5Status.isCharging);

    // 低电量提醒逻辑
    for (var dev in devices) {
      if (dev.isConnected) {
        if (lowBatteryAlert && dev.batteryLevel <= 20 && !dev.isCharging) {
          if (!(_hasAlertedLowBattery[dev.name] ?? false)) {
            _hasAlertedLowBattery[dev.name] = true;
            onShowAlert?.call('⚠️ 提醒：${dev.name} 电量低 (${dev.batteryLevel}%)，请及时充电！');
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
      if (devices.any((d) => d.isConnected) && (_pollingTimer == null || !_pollingTimer!.isActive)) {
        _startTimer();
        _fetchData();
      }
    }
  }
}

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
      builder: (_, ThemeMode currentMode, _) {
        return MaterialApp(
          title: '外设电量',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.light), useMaterial3: true),
          darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark), useMaterial3: true),
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

class _MainNavigationScreenState extends State<MainNavigationScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  final List<Widget> _pages = const [MockSwitchesPage(), InteractionPage()];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    globalMonitor.onShowAlert = (msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating, backgroundColor: msg.contains('⚠️') ? Colors.redAccent : null));
      }
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => globalMonitor.handleLifecycleChange(state);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('外设电量'),
        centerTitle: true,
        actions: [
          IconButton(icon: Icon(themeNotifier.value == ThemeMode.light ? Icons.dark_mode : Icons.light_mode), onPressed: () => themeNotifier.value = themeNotifier.value == ThemeMode.light ? ThemeMode.dark : ThemeMode.light)
        ],
      ),
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (int index) => setState(() => _currentIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.toggle_on_outlined), selectedIcon: Icon(Icons.toggle_on), label: '全局设置'),
          NavigationDestination(icon: Icon(Icons.hub_outlined), selectedIcon: Icon(Icons.hub), label: '设备状态'),
        ],
      ),
    );
  }
}

// ==================== 页面1：设置页 ====================
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
            Card(
              elevation: 0,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Column(
                children: [
                  SwitchListTile(title: const Text('蓝牙/2.4G 自动轮询'), subtitle: const Text('启动时自动寻找已知设备'), value: globalMonitor.autoConnect, onChanged: (v) => globalMonitor.updateSettings(auto: v)),
                  const Divider(height: 1),
                  SwitchListTile(title: const Text('后台状态监测'), subtitle: const Text('应用最小化时持续获取信息'), value: globalMonitor.backgroundMonitor, onChanged: (v) => globalMonitor.updateSettings(background: v)),
                  const Divider(height: 1),
                  SwitchListTile(title: const Text('低电量通知提醒'), subtitle: const Text('设备低于 20% 弹出提醒'), value: globalMonitor.lowBatteryAlert, onChanged: (v) => globalMonitor.updateSettings(lowBattery: v)),
                ],
              ),
            ),
          ],
        );
      }
    );
  }
}

// ==================== 页面2：设备监测列表页 ====================
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
        final isAnyConnected = globalMonitor.devices.any((d) => d.isConnected);

        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16.0),
                itemCount: globalMonitor.devices.length,
                itemBuilder: (context, index) {
                  final dev = globalMonitor.devices[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    elevation: 4,
                    shadowColor: Colors.black26,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Row(
                        children: [
                          Icon(dev.icon, size: 48, color: dev.isConnected ? Theme.of(context).colorScheme.primary : Colors.grey),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(dev.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                Text(dev.isConnected ? '已连接' : '未发现设备', style: TextStyle(color: dev.isConnected ? Colors.green : Colors.grey)),
                              ],
                            ),
                          ),
                          if (dev.isConnected)
                            Column(
                              children: [
                                Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    CircularProgressIndicator(value: dev.batteryLevel / 100, backgroundColor: Colors.grey.shade300, valueColor: AlwaysStoppedAnimation<Color>(_getBatteryColor(dev.batteryLevel))),
                                    Icon(dev.isCharging ? Icons.bolt : Icons.battery_std, size: 16, color: _getBatteryColor(dev.batteryLevel)),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text('${dev.batteryLevel}%', style: const TextStyle(fontWeight: FontWeight.bold)),
                              ],
                            )
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24.0),
              child: FilledButton.icon(
                onPressed: isAnyConnected ? globalMonitor.disconnect : globalMonitor.connectAndMonitor,
                icon: Icon(isAnyConnected ? Icons.stop_circle : Icons.play_arrow),
                label: Text(isAnyConnected ? '停止所有监测' : '一键扫描设备电量'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(double.infinity, 60),
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  backgroundColor: isAnyConnected ? Colors.red.shade400 : null,
                ),
              ),
            ),
          ],
        );
      }
    );
  }
}