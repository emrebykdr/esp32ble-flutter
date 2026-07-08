import 'package:flutter/material.dart';
import '../core/app_colors.dart';

// LED (kırmızı/yeşil/mavi) ve röle switch'lerini gösteren kart
class LedRelayCard extends StatelessWidget {
  final bool redLed;
  final bool greenLed;
  final bool blueLed;
  final bool relay;

  final Function(bool) onRedChanged;
  final Function(bool) onGreenChanged;
  final Function(bool) onBlueChanged;
  final Function(bool) onRelayChanged;

  const LedRelayCard({
    super.key,
    required this.redLed,
    required this.greenLed,
    required this.blueLed,
    required this.relay,
    required this.onRedChanged,
    required this.onGreenChanged,
    required this.onBlueChanged,
    required this.onRelayChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'LED & RÖLE',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _LedRow(label: 'Kırmızı LED', dotColor: Colors.red,   value: redLed,   onChanged: onRedChanged),
            _LedRow(label: 'Yeşil LED',   dotColor: Colors.green, value: greenLed, onChanged: onGreenChanged),
            _LedRow(label: 'Mavi LED',    dotColor: Colors.blue,  value: blueLed,  onChanged: onBlueChanged),
            _LedRow(label: 'Röle',        dotColor: AppColors.textMuted, value: relay, onChanged: onRelayChanged),
          ],
        ),
      ),
    );
  }
}

// Tek bir satır: renkli nokta + isim + switch (4 kez tekrar etmemek için ayrı widget yaptık)
class _LedRow extends StatelessWidget {
  final String label;
  final Color dotColor;
  final bool value;
  final Function(bool) onChanged;

  const _LedRow({
    required this.label,
    required this.dotColor,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dotColor,
              boxShadow: value
                  ? [
                      BoxShadow(
                        color: dotColor.withValues(alpha: 0.7),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: dotColor,
            activeTrackColor: dotColor.withValues(alpha: 0.3),
          ),
        ],
      ),
    );
  }
}
