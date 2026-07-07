import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_service.dart';
import 'ble_device_model.dart';
import 'core/app_colors.dart';
import 'core/app_responsive.dart';
import 'widgets/scan_button.dart';
import 'widgets/device_list.dart';
import 'widgets/connected_card.dart';

// Ana ekran: cihaz tarama ve bağlanma akışını yönetir.
// LED/röle kontrolü ve sensör verisi kısmı henüz eklenmedi.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _bleService = BleService();

  List<BleDeviceModel> _devices = [];
  bool _isScanning = false;
  bool _isConnected = false;
  String _connectedName = '';

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _listenStreams();
  }

  // Android BLE için gerekli izinleri ister
  Future<void> _requestPermissions() async {
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
      setState(() => _isConnected = connected);
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
    await _bleService.connect(device);
    setState(() => _connectedName = device.name);
  }

  Future<void> _disconnect() async {
    await _bleService.disconnect();
    setState(() => _connectedName = '');
  }

  @override
  void dispose() {
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

              ScanButton(
                isScanning: _isScanning,
                onPressed: _toggleScan,
              ),
              const SizedBox(height: 8),

              // Bulunan cihazlar listesi — cihaz varsa göster
              if (_devices.isNotEmpty)
                DeviceList(
                  devices: _devices,
                  onDeviceTap: _connectToDevice,
                ),

              // Bağlı cihaz kartı — bağlıysa göster
              if (_isConnected) ...[
                const SizedBox(height: 8),
                ConnectedCard(
                  deviceName: _connectedName,
                  onDisconnect: _disconnect,
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
