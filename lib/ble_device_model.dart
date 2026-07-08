import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// Taramada bulunan tek bir BLE cihazını temsil eder.
// flutter_blue_plus'ın ham ScanResult'ını UI'ın anlayacağı basit bir modele çevirir.
class BleDeviceModel {
  final String id; // Cihazın MAC adresi (remoteId) — benzersiz kimlik olarak kullanılır
  final String name; // Cihazın yayınladığı isim, listede gösterilir
  final int rssi; // Sinyal gücü (dBm) — 0'a ne kadar yakınsa sinyal o kadar güçlü
  final BluetoothDevice device; // Bağlan/kes işlemleri için gereken gerçek BLE nesnesi

  BleDeviceModel({
    required this.id,
    required this.name,
    required this.rssi,
    required this.device,
  });
}
