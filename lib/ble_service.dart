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
  Timer? _sensorPollTimer;

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

  // Web Bluetooth, discoverServices'ten önce hangi custom servise erişileceğini
  // bilmek zorunda (optionalServices), aksi halde SecurityError atar.
  static final Guid _serviceUuid = Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');

  // 10 saniye boyunca çevredeki BLE cihazlarını tarar
  Future<void> startScan() async {
    if (!kIsWeb) {
      if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
      }
    }

    _foundDevices.clear();

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 10),
      webOptionalServices: [_serviceUuid],
    );

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

    // Windows'ta Chrome'un Web Bluetooth (WinRT) katmanı, bağlantı hemen sonrası
    // GATT işlemlerinde (özellikle notify descriptor yazımı) zaman zaman takılıyor;
    // kısa bir bekleme GATT session'ının tam kurulmasına fırsat veriyor.
    if (kIsWeb) {
      await Future.delayed(const Duration(milliseconds: 600));
    }

    final services = await model.device.discoverServices();
    for (var service in services) {
      debugPrint('Servis bulundu: ${service.uuid}');
      for (var c in service.characteristics) {
        if (c.properties.write) {
          // LED/röle komutları bu karakteristiğe yazılacak
          _writeCharacteristic = c;
        } else if (c.properties.notify) {
          // ESP32 mesafe verisini bu karakteristikten notify ile gönderiyor.
          if (kIsWeb) {
            // Windows Chrome'da startNotifications() (bilinen Chromium/WinRT bug'ı)
            // bu karakteristikte hep timeout veriyor; readValue() ise sorunsuz çalışıyor
            // (chrome://bluetooth-internals ile doğrulandı). Push yerine periyodik
            // okuma (polling) ile aynı bozuk API yolunu tamamen atlıyoruz.
            _sensorPollTimer?.cancel();
            _sensorPollTimer = Timer.periodic(
              const Duration(milliseconds: 500),
              (_) async {
                try {
                  final value = await c.read();
                  _handleSensorValue(value);
                } catch (e) {
                  debugPrint('Sensor read hatasi: $e');
                }
              },
            );
          } else {
            await _enableNotifyWithRetry(c);
            c.lastValueStream.listen(_handleSensorValue);
          }
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

  // ESP32'den gelen ham byte'ı (string "23" gibi) int mesafeye çevirip stream'e ekler
  void _handleSensorValue(List<int> value) {
    if (value.isNotEmpty) {
      final str = String.fromCharCodes(value);
      final distance = int.tryParse(str);
      if (distance != null) {
        _sensorController.add(distance);
      }
    }
  }

  // Windows Chrome'da startNotifications() ilk denemede timeout verebiliyor,
  // birkaç kez tekrar deneyip geçmesini bekliyoruz.
  Future<void> _enableNotifyWithRetry(
    BluetoothCharacteristic c, {
    int maxAttempts = 3,
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await c.setNotifyValue(true);
        return;
      } catch (e) {
        debugPrint('setNotifyValue deneme $attempt basarisiz: $e');
        if (attempt == maxAttempts) rethrow;
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
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
    _sensorPollTimer?.cancel();
    _sensorPollTimer = null;
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
    _connectionController.add(false);
  }

  // Servis yok edilirken stream'leri kapat, aksi halde memory leak olur
  void dispose() {
    _sensorPollTimer?.cancel();
    _devicesController.close();
    _connectionController.close();
    _sensorController.close();
  }
}
