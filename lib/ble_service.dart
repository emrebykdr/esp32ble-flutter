import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ble_device_model.dart';
import 'package:flutter/foundation.dart';

// Şu an için sadece tarama ve bağlanma sorumluluğu var.
// LED/röle kontrolü ve sensör verisi ileride eklenecek.
class BleService {
  final List<BleDeviceModel> _foundDevices = [];
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;

  final _devicesController = StreamController<List<BleDeviceModel>>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _sensorController = StreamController<int>.broadcast();

  // Taranan cihaz listesi UI'a bu stream üzerinden akar
  Stream<List<BleDeviceModel>> get devicesStream => _devicesController.stream;
  // Bağlantı durumu (true/false) UI'a bu stream üzerinden akar
  Stream<bool> get connectionStream => _connectionController.stream;
  // ESP32'den notify ile gelen mesafe verisi (cm) bu stream üzerinden akar
  Stream<int> get sensorStream => _sensorController.stream;

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
          // Yeni kopya gönder, aksi halde ValueNotifier/StreamBuilder değişikliği fark etmez
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
    final services = await model.device.discoverServices();
    for (var service in services) {
      debugPrint('Servis bulundu: ${service.uuid}');
      for (var c in service.characteristics) {
        if (c.properties.write) {
          // LED/röle komutları bu karakteristiğe yazılacak
          _writeCharacteristic = c;
        } else if (c.properties.notify) {
          // ESP32 mesafe verisini bu karakteristikten notify ile gönderiyor
          await c.setNotifyValue(true);
          c.lastValueStream.listen((value) {
            if (value.isNotEmpty) {
              // ESP32 veriyi string olarak gönderiyor (örn. "23"), int'e çeviriyoruz
              final str = String.fromCharCodes(value);
              final distance = int.tryParse(str);
              if (distance != null) {
                _sensorController.add(distance);
              }
            }
          });
        }
        debugPrint(
          '  -> Karakteristik: ${c.uuid} (write: ${c.properties.write}, notify: ${c.properties.notify})',
        );
      }
    }

    // Cihaz beklenmedik şekilde koparsa (menzil dışı, pil vs.) durumu güncelle
    model.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _connectedDevice = null;
        _connectionController.add(false);
      }
    });

    _connectionController.add(true);
  }

  // LED ve Röle için byte komut tablosu — ESP32 tarafı bu byte'lara göre çalışacak
  static const int redLedOn = 0x11;
  static const int redLedOff = 0x10;
  static const int greenLedOn = 0x21;
  static const int greenLedOff = 0x20;
  static const int blueLedOn = 0x31;
  static const int blueLedOff = 0x30;
  static const int relayOn = 0x41;
  static const int relayOff = 0x40;

  // Verilen byte komutunu ESP32'ye gönderir
  Future<void> sendCommand(int command) async {
    if (_writeCharacteristic == null) return;
    await _writeCharacteristic!.write([command]);
  }

  // Kullanıcı manuel bağlantıyı keser
  Future<void> disconnect() async {
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
    _connectionController.add(false);
  }

  // Servis yok edilirken stream'leri kapat, aksi halde memory leak olur
  void dispose() {
    _devicesController.close();
    _connectionController.close();
    _sensorController.close();
  }
}
