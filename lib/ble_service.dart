import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'ble_device_model.dart';
import 'package:flutter/foundation.dart';

// ESP32 ile BLE üzerinden tarama, bağlanma, LED/röle komutu gönderme
// ve mesafe sensörü verisini okuma sorumluluğu bu serviste toplanıyor.
class BleService {
  final List<BleDeviceModel> _foundDevices = [];
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;
  Timer? _sensorPollTimer;
  // startScan()/connect() her çağrıldığında yeniden abone olunmadan önce
  // öncekini iptal etmek için tutuluyor — aksi halde tekrar tekrar
  // tarama/bağlanma yapıldıkça aynı olaylar birden fazla kez işlenir.
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<int>>? _lastValueSubscription;
  // disconnect() çağrıldığında true olur; connectionState listener'ının
  // bunu beklenmedik kopma sanıp hata göstermesini önler.
  bool _expectingDisconnect = false;

  final _devicesController = StreamController<List<BleDeviceModel>>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();
  final _sensorController = StreamController<int>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  // Taranan cihaz listesi UI'a bu stream üzerinden akar
  Stream<List<BleDeviceModel>> get devicesStream => _devicesController.stream;
  // Bağlantı durumu (true/false) UI'a bu stream üzerinden akar
  Stream<bool> get connectionStream => _connectionController.stream;
  // ESP32'den notify ile gelen mesafe verisi (cm) bu stream üzerinden akar
  Stream<int> get sensorStream => _sensorController.stream;
  // Kullanıcıya gösterilecek hata mesajları (örn. beklenmedik kopma) bu stream'den akar
  Stream<String> get errorStream => _errorController.stream;

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

    _scanResultsSubscription?.cancel();
    _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
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
              (timer) async {
                // Bağlantı koptuysa timer'ı hemen durdur; connectionState
                // listener'ının bunu fark etmesini beklemek gereksiz
                // "GATT Server is disconnected" hatalarına yol açıyordu.
                if (!model.device.isConnected) {
                  timer.cancel();
                  return;
                }
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
            _lastValueSubscription?.cancel();
            _lastValueSubscription = c.lastValueStream.listen(_handleSensorValue);
          }
        }
        debugPrint(
          '  -> Karakteristik: ${c.uuid} (write: ${c.properties.write}, notify: ${c.properties.notify})',
        );
      }
    }

    // Cihaz beklenmedik şekilde koparsa (menzil dışı, pil vs.) durumu güncelle
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = model.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        final wasExpected = _expectingDisconnect;
        _expectingDisconnect = false;
        _sensorPollTimer?.cancel();
        _connectedDevice = null;
        _connectionController.add(false);
        if (!wasExpected) {
          _errorController.add('Bağlantı beklenmedik şekilde kesildi');
        }
      }
    });

    _connectionController.add(true);
  }

  // ESP32'den gelen ham byte'ı (string "23" gibi) int mesafeye çevirip stream'e ekler.
  // ESP32 ölçüm alamazsa -1 gönderiyor; bunu geçerli veri sayıp ekranı
  // güncellemiyoruz, aksi halde stale (bayat veri) göstergesi tetiklenmez.
  void _handleSensorValue(List<int> value) {
    if (value.isNotEmpty) {
      final str = String.fromCharCodes(value);
      final distance = int.tryParse(str);
      if (distance != null && distance >= 0) {
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

  // LED ve Röle için metin komut tablosu — ESP32 tarafı bu string'lere göre çalışacak
  static const String redLedOn = 'RED_ON';
  static const String redLedOff = 'RED_OFF';
  static const String greenLedOn = 'GREEN_ON';
  static const String greenLedOff = 'GREEN_OFF';
  static const String blueLedOn = 'BLUE_ON';
  static const String blueLedOff = 'BLUE_OFF';
  static const String relayOn = 'RELAY_ON';
  static const String relayOff = 'RELAY_OFF';

  // Verilen metin komutunu ESP32'ye gönderir
  Future<void> sendCommand(String command) async {
    if (_writeCharacteristic == null) return;
    try {
      await _writeCharacteristic!.write(utf8.encode(command));
    } catch (e) {
      debugPrint('sendCommand hatasi: $e');
      _errorController.add('Komut gönderilemedi: $command');
    }
  }

  // Kullanıcı manuel bağlantıyı keser
  Future<void> disconnect() async {
    _expectingDisconnect = true;
    _sensorPollTimer?.cancel();
    _sensorPollTimer = null;
    _connectionStateSubscription?.cancel();
    _lastValueSubscription?.cancel();
    await _connectedDevice?.disconnect();
    _connectedDevice = null;
    _connectionController.add(false);
  }

  // Servis yok edilirken stream'leri kapat, aksi halde memory leak olur
  void dispose() {
    _sensorPollTimer?.cancel();
    _scanResultsSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _lastValueSubscription?.cancel();
    _devicesController.close();
    _connectionController.close();
    _sensorController.close();
    _errorController.close();
  }
}
