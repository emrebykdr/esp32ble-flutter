import 'package:flutter/material.dart';
import '../core/app_colors.dart';

// Mesafe sensörü (HC-SR04) değerini gösteren kart
class SensorCard extends StatelessWidget {
  final int? distanceCm;

  const SensorCard({super.key, required this.distanceCm});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'MESAFE SENSÖRÜ',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              distanceCm != null ? '$distanceCm cm' : '--',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
