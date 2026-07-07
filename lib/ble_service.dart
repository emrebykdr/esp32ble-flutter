import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ble_device_model.dart';

// Şu an için sadece tarama ve bağlanma sorumluluğu var.
// LED/röle kontrolü ve sensör verisi ileride eklenecek.
class BleService {
  final List<BleDeviceModel> _foundDevices = [];
  BluetoothDevice? _connectedDevice;

  final _devicesController = StreamController<List<BleDeviceModel>>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();

  Stream<List<BleDeviceModel>> get devicesStream => _devicesController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;

  bool get isConnected => _connectedDevice != null;

  // 10 saniye boyunca çevredeki BLE cihazlarını tarar
  Future<void> startScan() async {
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      await FlutterBluePlus.turnOn();
    }

    _foundDevices.clear();

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult result in results) {
        final name = result.device.platformName;
        if (name.isEmpty) continue;

        final exists = _foundDevices.any(
          (d) => d.id == result.device.remoteId.str,
        );
        if (!exists) {
          _foundDevices.add(
            BleDeviceModel(
              id: result.device.remoteId.str,
              name: name,
              rssi: result.rssi,
              device: result.device,
            ),
          );
          _devicesController.add(List.from(_foundDevices));
        }
      }
    });
  }

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  // Seçilen cihaza bağlanır ve bağlantı durumunu stream'e gönderir
  Future<void> connect(BleDeviceModel model) async {
    await model.device.connect();
    _connectedDevice = model.device;

    model.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _connectedDevice = null;
        _connectionController.add(false);
      }
    });

    _connectionController.add(true);
  }

  Future<void> disconnect() async {
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
    _connectionController.add(false);
  }

  void dispose() {
    _devicesController.close();
    _connectionController.close();
  }
}
