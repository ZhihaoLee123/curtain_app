import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const CurtainApp());
}

class CurtainApp extends StatelessWidget {
  const CurtainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '智能窗帘',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const MainPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});
  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  // ============ UUID 配置（UART Service）============
  final String _serviceUUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  final String _rxCharUUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
  final String _txCharUUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

  // ============ 蓝牙设备相关变量 ============
  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeCharacteristic; // 用于发送指令（RX）
  BluetoothCharacteristic? _notifyCharacteristic; // 用于接收通知（TX）
  StreamSubscription? _notifySub;
  List<ScanResult> _devices = [];

  // ============ 状态变量 ============
  bool _isScanning = false;
  bool _isConnected = false;
  bool _isCurtainOpen = false;
  bool _isAutoMode = false; // Auto 模式标志
  String _statusText = '未连接';

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  // ============ 申请权限 ============
  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  // ============ 扫描设备 ============
  void _startScan() {
    setState(() {
      _devices.clear();
      _isScanning = true;
      _statusText = '扫描附近设备中...';
    });

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

    FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        _devices = results.where((r) => r.device.platformName.isNotEmpty).toList();
      });
    });

    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() {
          _isScanning = false;
          _statusText = _devices.isEmpty ? '没找到设备，请确保舵机上电' : '请点击你的设备连接';
        });
      }
    });
  }

  // ============ 连接设备 ============
  Future<void> _connect(BluetoothDevice device) async {
    FlutterBluePlus.stopScan();
    setState(() => _statusText = '连接中...');

    try {
      await device.connect(timeout: const Duration(seconds: 5));

      // 发现服务
      List<BluetoothService> services = await device.discoverServices();
      BluetoothCharacteristic? foundRxChar;
      BluetoothCharacteristic? foundTxChar;

      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == _serviceUUID.toLowerCase()) {
          for (var c in service.characteristics) {
            final uuid = c.uuid.toString().toLowerCase();
            if (uuid == _rxCharUUID.toLowerCase()) {
              foundRxChar = c;
            } else if (uuid == _txCharUUID.toLowerCase()) {
              foundTxChar = c;
            }
            if (foundRxChar != null && foundTxChar != null) {
              break;
            }
          }
        }
        if (foundRxChar != null && foundTxChar != null) {
          break;
        }
      }

      // 检查是否找到
      if (foundRxChar == null || foundTxChar == null) {
        setState(() => _statusText = '连接失败：找不到UART服务的RX或TX特征！');
        await device.disconnect();
        return;
      }

      // 开启通知监听
      await foundTxChar.setNotifyValue(true);
      _notifySub = foundTxChar.onValueReceived.listen((value) {
        String msg = utf8.decode(value).trim();
        print("收到ESP32消息: $msg");

        setState(() {
          if (msg.contains("OPENED")) {
            _isCurtainOpen = true;
            _statusText = '窗帘已打开 ☀️';
          } else if (msg.contains("CLOSED")) {
            _isCurtainOpen = false;
            _statusText = '窗帘已关闭 🌙';
          } else {
            _statusText = 'ESP32消息: $msg';
          }
        });
      });

      setState(() {
        _device = device;
        _writeCharacteristic = foundRxChar;
        _notifyCharacteristic = foundTxChar;
        _isConnected = true;
        _isAutoMode = false;
        _statusText = '连接成功！';
      });

      // 监听断开连接
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            _isConnected = false;
            _statusText = '连接已断开';
            _device = null;
            _writeCharacteristic = null;
            _notifyCharacteristic = null;
            _isAutoMode = false;
          });
        }
      });

    } catch (e) {
      setState(() => _statusText = '连接报错: $e');
    }
  }

  // ============ 发送指令给ESP32 ============
  Future<void> _sendCommand(String command) async {
    if (_writeCharacteristic == null) {
      setState(() => _statusText = '发送失败：未找到写入特征');
      return;
    }
    try {
      await _writeCharacteristic!.write(utf8.encode(command));
      setState(() => _statusText = '指令已发送: $command...');
    } catch (e) {
      setState(() => _statusText = '发送失败: $e');
    }
  }

  // ============ 切换 Auto 模式 ============
  Future<void> _toggleAutoMode() async {
    if (_isAutoMode) {
      // 关闭 Auto 模式
      await _sendCommand("MANUAL");
      setState(() {
        _isAutoMode = false;
        _statusText = '已切换到手动模式';
      });
    } else {
      // 启用 Auto 模式
      await _sendCommand("AUTO");
      setState(() {
        _isAutoMode = true;
        _statusText = '已切换到自动模式 (光敏电阻控制)';
      });
    }
  }

  // ============ 断开连接 ============
  void _disconnect() async {
    await _device?.disconnect();
  }

  // ============ 界面 UI ============
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('蓝牙窗帘控制器'),
        actions: [
          Icon(
            _isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
            color: _isConnected ? Colors.green : Colors.grey,
          ),
          const SizedBox(width: 20),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // 状态展示卡片
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 40),
              decoration: BoxDecoration(
                color: _isCurtainOpen ? Colors.blue.shade50 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Icon(
                    _isCurtainOpen ? Icons.curtains : Icons.curtains_closed,
                    size: 100,
                    color: _isCurtainOpen ? Colors.blue : Colors.grey.shade600,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _statusText,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _isAutoMode ? '🤖 自动模式' : '🎮 手动模式',
                    style: TextStyle(
                      fontSize: 16,
                      color: _isAutoMode ? Colors.blue : Colors.green,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),

            // 控制面板
            if (_isConnected) ...[
              // Auto 模式切换按钮
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _toggleAutoMode,
                  icon: Icon(_isAutoMode ? Icons.light_mode : Icons.light_mode_outlined),
                  label: Text(
                    _isAutoMode ? '取消自动模式' : '启用自动模式',
                    style: const TextStyle(fontSize: 16),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isAutoMode ? Colors.orange : Colors.amber.shade200,
                  ),
                ),
              ),
              const SizedBox(height: 15),

              // 手动控制按钮（Auto 模式时禁用）
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    onPressed: _isAutoMode ? null : () => _sendCommand("OPEN"),
                    icon: const Icon(Icons.wb_sunny),
                    label: const Text('开窗帘', style: TextStyle(fontSize: 18)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                      backgroundColor: Colors.blue.shade100,
                      disabledBackgroundColor: Colors.grey.shade300,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: _isAutoMode ? null : () => _sendCommand("CLOSE"),
                    icon: const Icon(Icons.nightlight_round),
                    label: const Text('关窗帘', style: TextStyle(fontSize: 18)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                      backgroundColor: Colors.indigo.shade100,
                      disabledBackgroundColor: Colors.grey.shade300,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              TextButton(
                onPressed: _disconnect,
                child: const Text('断开蓝牙', style: TextStyle(color: Colors.red)),
              ),
            ] else ...[
              // 扫描设备区
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _isScanning ? null : _startScan,
                  icon: _isScanning
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  label: Text(_isScanning ? '正在扫描...' : '扫描蓝牙设备'),
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView.builder(
                  itemCount: _devices.length,
                  itemBuilder: (context, index) {
                    final d = _devices[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.bluetooth),
                        title: Text(d.device.platformName),
                        subtitle: Text(d.device.remoteId.toString()),
                        trailing: const Text('点击连接', style: TextStyle(color: Colors.blue)),
                        onTap: () => _connect(d.device),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}