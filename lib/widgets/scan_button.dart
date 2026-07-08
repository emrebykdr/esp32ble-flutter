import 'package:flutter/material.dart';
import '../core/app_colors.dart';

// Tarama başlat/durdur butonu
class ScanButton extends StatefulWidget {
  final bool isScanning; // Şu an tarama yapılıyor mu
  final VoidCallback onPressed; // Butona basılınca çağrılır

  const ScanButton({
    super.key,
    required this.isScanning,
    required this.onPressed,
  });

  @override
  State<ScanButton> createState() => _ScanButtonState();
}

class _ScanButtonState extends State<ScanButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.isScanning) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant ScanButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isScanning && !oldWidget.isScanning) {
      _controller.repeat();
    } else if (!widget.isScanning && oldWidget.isScanning) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          // Tararken border yeşile döner, hafif pulse ile glow verir
          final pulse = widget.isScanning
              ? (0.5 + 0.5 * (1 - (_controller.value - 0.5).abs() * 2))
              : 0.0;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.isScanning
                    ? AppColors.accent.withValues(alpha: 0.4 + pulse * 0.4)
                    : AppColors.cardBorder,
                width: 1,
              ),
              boxShadow: widget.isScanning
                  ? [
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.15 + pulse * 0.2),
                        blurRadius: 16,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: Material(
                color: AppColors.card,
                child: InkWell(
                  onTap: widget.onPressed,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              widget.isScanning ? 'Taranıyor...' : 'Cihazları Tara',
                              style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            // Tararken dönen gösterge, değilse tarama ikonu
                            widget.isScanning
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
                        if (widget.isScanning) ...[
                          const SizedBox(height: 14),
                          _SweepLine(progress: _controller.value),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// Tarama sırasında soldan sağa kayan ince ışık çizgisi
class _SweepLine extends StatelessWidget {
  final double progress;

  const _SweepLine({required this.progress});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 2,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final stripeWidth = w * 0.4;
          // -stripeWidth'ten w'ye kadar kayar, kenarlarda kaybolur
          final left = -stripeWidth + progress * (w + stripeWidth);
          return ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(
              children: [
                Container(color: AppColors.cardBorder),
                Positioned(
                  left: left,
                  width: stripeWidth,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.accent.withValues(alpha: 0),
                          AppColors.accent,
                          AppColors.accent.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
