import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_service.dart';
import 'ble_device_model.dart';
import 'core/app_colors.dart';
import 'core/app_responsive.dart';
import 'widgets/scan_button.dart';
import 'widgets/device_list.dart';
import 'widgets/connected_card.dart';
import 'widgets/led_relay_card.dart';
import 'widgets/sensor_card.dart';

// Ana ekran: cihaz tarama ve bağlanma akışını yönetir.
// LED/röle kontrolü ve sensör verisi kısmı henüz eklenmedi.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _bleService = BleService();

  static const int _maxHistoryLength = 40;
  // Bu süre boyunca yeni sensör okuması gelmezse veri "bayat" sayılır
  // (ESP32 her ~500ms'de bir gönderiyor, 2sn ~4 kaçırılan tura karşılık gelir)
  static const Duration _staleThreshold = Duration(seconds: 2);

  List<BleDeviceModel> _devices = [];
  bool _isScanning = false;
  bool _isConnecting = false;
  bool _isConnected = false;
  int? _distance;
  final List<int> _distanceHistory = [];
  DateTime? _lastSensorUpdate;
  bool _isSensorStale = false;
  Timer? _staleCheckTimer;
  String _connectedName = '';

  bool _redLed = false;
  bool _greenLed = false;
  bool _blueLed = false;
  bool _relay = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _listenStreams();
    _staleCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_lastSensorUpdate == null || !_isConnected) return;
      final isStale = DateTime.now().difference(_lastSensorUpdate!) > _staleThreshold;
      if (isStale != _isSensorStale) {
        setState(() => _isSensorStale = isStale);
      }
    });
  }

  // Android BLE için gerekli izinleri ister
  Future<void> _requestPermissions() async {
    if (kIsWeb) return;
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.locationWhenInUse.request();
  }

  // BleService stream'lerini dinler ve state'i günceller
  void _listenStreams() {
    _bleService.devicesStream.listen((devices) {
      setState(() => _devices = devices);
    });

    _bleService.connectionStream.listen((connected) {
      setState(() {
        _isConnected = connected;
        if (!connected) {
          _redLed = false;
          _greenLed = false;
          _blueLed = false;
          _relay = false;
          _distance = null;
          _distanceHistory.clear();
          _lastSensorUpdate = null;
          _isSensorStale = false;
        }
      });
    });
    _bleService.sensorStream.listen((distance) {
      setState(() {
        _distance = distance;
        _distanceHistory.add(distance);
        if (_distanceHistory.length > _maxHistoryLength) {
          _distanceHistory.removeAt(0);
        }
        _lastSensorUpdate = DateTime.now();
        _isSensorStale = false;
      });
    });

    _bleService.errorStream.listen((message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    });
  }

  // Tarama butonuna basılınca çağrılır
  Future<void> _toggleScan() async {
    if (_isScanning) {
      await _bleService.stopScan();
      setState(() => _isScanning = false);
    } else {
      setState(() => _isScanning = true);
      try {
        await _bleService.startScan();
      } catch (e) {
        debugPrint('Tarama hatası: $e');
      } finally {
        setState(() => _isScanning = false);
      }
    }
  }

  // Listeden cihaz seçilince bağlantı kurar
  Future<void> _connectToDevice(BleDeviceModel device) async {
    setState(() => _isConnecting = true);
    try {
      await _bleService.connect(device);
      setState(() => _connectedName = device.name);
    } catch (e) {
      debugPrint('Bağlantı hatası: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${device.name} cihazına bağlanılamadı')),
        );
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnect() async {
    // Bağlantı kesilmeden önce açık LED/röle varsa kapat, aksi halde donanımda yanık kalır
    if (_redLed) await _bleService.sendCommand(BleService.redLedOff);
    if (_greenLed) await _bleService.sendCommand(BleService.greenLedOff);
    if (_blueLed) await _bleService.sendCommand(BleService.blueLedOff);
    if (_relay) await _bleService.sendCommand(BleService.relayOff);

    await _bleService.disconnect();
    setState(() => _connectedName = '');
  }

  @override
  void dispose() {
    _staleCheckTimer?.cancel();
    _bleService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = Responsive(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: r.horizontalPadding,
            vertical: 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 16),

              ScanButton(isScanning: _isScanning, onPressed: _toggleScan),
              const SizedBox(height: 8),

              // Bulunan cihazlar listesi — cihaz varsa göster
              if (_devices.isNotEmpty)
                DeviceList(
                  devices: _devices,
                  isConnecting: _isConnecting,
                  onDeviceTap: _connectToDevice,
                ),

              // Bağlı cihaz kartı — bağlıysa göster
              if (_isConnected) ...[
                const SizedBox(height: 8),
                ConnectedCard(
                  deviceName: _connectedName,
                  onDisconnect: _disconnect,
                ),
                const SizedBox(height: 8),
                LedRelayCard(
                  redLed: _redLed,
                  greenLed: _greenLed,
                  blueLed: _blueLed,
                  relay: _relay,
                  onRedChanged: (v) {
                    setState(() => _redLed = v);
                    _bleService.sendCommand(
                      v ? BleService.redLedOn : BleService.redLedOff,
                    );
                  },
                  onGreenChanged: (v) {
                    setState(() => _greenLed = v);
                    _bleService.sendCommand(
                      v ? BleService.greenLedOn : BleService.greenLedOff,
                    );
                  },
                  onBlueChanged: (v) {
                    setState(() => _blueLed = v);
                    _bleService.sendCommand(
                      v ? BleService.blueLedOn : BleService.blueLedOff,
                    );
                  },
                  onRelayChanged: (v) {
                    setState(() => _relay = v);
                    _bleService.sendCommand(
                      v ? BleService.relayOn : BleService.relayOff,
                    );
                  },
                ),
                const SizedBox(height: 8),
                SensorCard(
                  distanceCm: _distance,
                  history: _distanceHistory,
                  isStale: _isSensorStale,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Ekran üst başlığı — ESP32 / BLE Controller + bağlantı durumu nokta
  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ESP32',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'BLE Controller',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ],
        ),
        // Yeşil: bağlı, gri: bağlı değil
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isConnected ? AppColors.accent : AppColors.textMuted,
          ),
        ),
      ],
    );
  }
}
