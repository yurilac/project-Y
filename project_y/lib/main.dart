import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:project_y/dualsense_driver.dart';
import 'dart:async';

// 全局主题控制器
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

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
          // 浅色主题配置
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blueAccent,
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          // 深色主题配置
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blueAccent,
              brightness: Brightness.dark,
            ),
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

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;

  // 页面列表
  final List<Widget> _pages = const [
    MockSwitchesPage(),
    InteractionPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设备控制器 Demo'),
        centerTitle: true,
        actions: [
          // 顶部的明暗主题切换按钮
          IconButton(
            icon: Icon(themeNotifier.value == ThemeMode.light
                ? Icons.dark_mode
                : Icons.light_mode),
            onPressed: () {
              themeNotifier.value = themeNotifier.value == ThemeMode.light
                  ? ThemeMode.dark
                  : ThemeMode.light;
            },
            tooltip: '切换主题',
          )
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _pages[_currentIndex],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (int index) {
          setState(() {
            _currentIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.toggle_on_outlined),
            selectedIcon: Icon(Icons.toggle_on),
            label: '设置与开关',
          ),
          NavigationDestination(
            icon: Icon(Icons.gamepad_outlined),
            selectedIcon: Icon(Icons.gamepad),
            label: '外设交互',
          ),
        ],
      ),
    );
  }
}

// ==================== 页面1：开关演示页 ====================
class MockSwitchesPage extends StatefulWidget {
  const MockSwitchesPage({super.key});

  @override
  State<MockSwitchesPage> createState() => _MockSwitchesPageState();
}

class _MockSwitchesPageState extends State<MockSwitchesPage> {
  bool _autoConnect = true;
  bool _backgroundMonitor = false;
  bool _lowBatteryAlert = true;

  @override
  Widget build(BuildContext context) {
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
                value: _autoConnect,
                onChanged: (bool value) => setState(() => _autoConnect = value),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('后台状态监测'),
                subtitle: const Text('应用最小化时持续获取信息'),
                value: _backgroundMonitor,
                onChanged: (bool value) => setState(() => _backgroundMonitor = value),
              ),
              const Divider(height: 1),
              SwitchListTile(
                title: const Text('低电量通知提醒'),
                subtitle: const Text('当设备电量低于 20% 时弹出系统通知'),
                value: _lowBatteryAlert,
                onChanged: (bool value) => setState(() => _lowBatteryAlert = value),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ==================== 页面2：交互演示页 ====================
class InteractionPage extends StatefulWidget {
  const InteractionPage({super.key});

  @override
  State<InteractionPage> createState() => _InteractionPageState();
}

class _InteractionPageState extends State<InteractionPage> {
  // 定义与底层 PC (C++/C#) 通信的通道
  static const platform = MethodChannel('com.device_monitor/dualsense');

  bool _isConnected = false;
  int _batteryLevel = 0;
  bool _isCharging = false;
  Timer? _pollingTimer;

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }


final _driver = DualSenseDriver();

Future<void> _fetchDualSenseData() async {
  // 在 Windows 上，这种底层 IO 建议配合 Future.sync 或 Isolate 执行
  final result = _driver.getBatteryStatus();

  setState(() {
    _isConnected = result.isConnected;
    if (_isConnected) {
      _batteryLevel = result.batteryLevel;
      _isCharging = result.isCharging;
    }
  });

  if (!_isConnected) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('未发现 DualSense 手柄，请确认蓝牙已连接。')),
    );
  }
}


  // // 模拟/请求读取手柄数据的核心方法
  // Future<void> _fetchDualSenseData() async {
  //   try {
  //     // 在实际生产环境中，这里会调用底层的 C++ 代码读取 HID 报告
  //     // final Map<dynamic, dynamic> result = await platform.invokeMethod('getControllerStatus');
      
  //     // 这里为了演示，我们使用模拟数据：每次点击模拟连接成功，并随机生成一个电量
  //     setState(() {
  //       _isConnected = true;
  //       _batteryLevel = (List.generate(10, (index) => (index + 1) * 10)..shuffle()).first; // 模拟 10% - 100%
  //       _isCharging = _batteryLevel < 100 && (DateTime.now().second % 2 == 0); // 随机模拟充电状态
  //     });

  //     // 开启轮询，每 5 秒读取一次真实外设状态
  //     _pollingTimer?.cancel();
  //     _pollingTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
  //       // 实际调用：await platform.invokeMethod('getControllerStatus');
  //     });

  //   } on PlatformException catch (e) {
  //     debugPrint("获取设备状态失败: '${e.message}'.");
  //     setState(() => _isConnected = false);
  //   }
  // }

  void _disconnect() {
    setState(() {
      _isConnected = false;
      _batteryLevel = 0;
      _isCharging = false;
    });
    _pollingTimer?.cancel();
  }

  // 根据电量决定指示器颜色
  Color _getBatteryColor(int level) {
    if (level > 50) return Colors.greenAccent;
    if (level > 20) return Colors.orangeAccent;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
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
                colors: _isConnected
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
                if (!_isConnected) ...[
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
                          value: _batteryLevel / 100,
                          strokeWidth: 12,
                          backgroundColor: Colors.white.withOpacity(0.2),
                          valueColor: AlwaysStoppedAnimation<Color>(_getBatteryColor(_batteryLevel)),
                          strokeCap: StrokeCap.round,
                        ),
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _isCharging ? Icons.bolt : Icons.battery_std,
                                color: Colors.white,
                                size: 28,
                              ),
                              Text(
                                '$_batteryLevel%',
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
            onPressed: _isConnected ? _disconnect : _fetchDualSenseData,
            icon: Icon(_isConnected ? Icons.bluetooth_disabled : Icons.bluetooth_connected),
            label: Text(_isConnected ? '断开设备监测' : '连接并读取电量'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 20),
              backgroundColor: _isConnected ? Colors.red.shade400 : null,
            ),
          ),
        ],
      ),
    );
  }
}