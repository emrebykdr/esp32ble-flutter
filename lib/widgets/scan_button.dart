import 'package:flutter/material.dart';
import '../core/app_colors.dart';

// Tarama başlat/durdur butonu
class ScanButton extends StatelessWidget {
  final bool isScanning; // Şu an tarama yapılıyor mu
  final VoidCallback onPressed; // Butona basılınca çağrılır

  const ScanButton({
    super.key,
    required this.isScanning,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Card(
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isScanning ? 'Taranıyor...' : 'Cihazları Tara',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                // Tararken dönen gösterge, değilse tarama ikonu
                isScanning
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.accent,
                        ),
                      )
                    : const Icon(
                        Icons.crop_free_rounded,
                        color: AppColors.accent,
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
