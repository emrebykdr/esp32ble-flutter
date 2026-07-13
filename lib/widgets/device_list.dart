import 'package:flutter/material.dart';
import '../core/app_colors.dart';
import '../ble_device_model.dart';

// Taramada bulunan cihazların listesi
class DeviceList extends StatelessWidget {
  final List<BleDeviceModel> devices; // Bulunan cihazlar
  final Function(BleDeviceModel) onDeviceTap; // Listeden bir cihaza dokununca çağrılır
  final bool isConnecting; // true iken taplar devre dışı, yükleniyor göstergesi çıkar

  const DeviceList({
    super.key,
    required this.devices,
    required this.onDeviceTap,
    this.isConnecting = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'BULUNAN CİHAZLAR',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (isConnecting)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // Her cihaz için bir satır oluştur
            ...devices.map((device) => _DeviceTile(
                  device: device,
                  onTap: isConnecting ? null : () => onDeviceTap(device),
                )),
          ],
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final BleDeviceModel device;
  final VoidCallback? onTap;

  const _DeviceTile({required this.device, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            // Sinyal güçlüyse vurgu rengi, zayıfsa soluk nokta
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: device.rssi > -60 ? AppColors.accent : AppColors.textMuted,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                device.name,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              '${device.rssi} dBm',
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
