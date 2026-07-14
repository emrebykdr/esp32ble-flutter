import 'package:flutter/material.dart';
import '../core/app_colors.dart';

// Mesafe sensörü (HC-SR04) değerini gösteren kart.
// Sağ üstteki grafik butonuyla son okumaların trendini gösteren
// basit bir çizgi grafik açılıp kapanabilir.
class SensorCard extends StatefulWidget {
  final int? distanceCm;
  final List<int> history;
  final bool isStale; // true iken bir süredir yeni okuma gelmemiş demektir

  const SensorCard({
    super.key,
    required this.distanceCm,
    this.history = const [],
    this.isStale = false,
  });

  @override
  State<SensorCard> createState() => _SensorCardState();
}

class _SensorCardState extends State<SensorCard>
    with SingleTickerProviderStateMixin {
  bool _showChart = false;
  late final AnimationController _blinkController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.isStale) _blinkController.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant SensorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isStale && !oldWidget.isStale) {
      _blinkController.repeat(reverse: true);
    } else if (!widget.isStale && oldWidget.isStale) {
      _blinkController.stop();
    }
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

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
                Row(
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
                    if (widget.isStale) ...[
                      const SizedBox(width: 6),
                      FadeTransition(
                        opacity: _blinkController,
                        child: const _StaleDot(),
                      ),
                    ],
                  ],
                ),
                // Grafik göster/gizle butonu — geçmiş veri yoksa devre dışı
                IconButton(
                  onPressed: widget.history.isEmpty
                      ? null
                      : () => setState(() => _showChart = !_showChart),
                  icon: Icon(
                    _showChart ? Icons.close : Icons.show_chart,
                    size: 18,
                    color: widget.history.isEmpty
                        ? AppColors.textMuted
                        : AppColors.accent,
                  ),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.distanceCm != null ? '${widget.distanceCm} cm' : '--',
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (_showChart) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 80,
                width: double.infinity,
                child: CustomPaint(
                  painter: _TrendPainter(widget.history),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Sensörden bir süredir veri gelmediğini belirten küçük kırmızı nokta
class _StaleDot extends StatelessWidget {
  const _StaleDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.redAccent,
      ),
    );
  }
}

// Son okumaları basit bir çizgi grafik olarak çizer, min/max'a göre otomatik ölçekler
class _TrendPainter extends CustomPainter {
  final List<int> values;

  _TrendPainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final minV = values.reduce((a, b) => a < b ? a : b).toDouble();
    final maxV = values.reduce((a, b) => a > b ? a : b).toDouble();
    // Tüm değerler aynıysa (düz çizgi) bölme hatası olmasın diye küçük bir aralık ver
    final range = (maxV - minV).abs() < 1 ? 1.0 : (maxV - minV);

    final stepX = size.width / (values.length - 1);
    double yFor(int v) =>
        size.height - ((v - minV) / range) * size.height;

    final linePath = Path();
    final fillPath = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i * stepX;
      final y = yFor(values[i]);
      if (i == 0) {
        linePath.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        linePath.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    canvas.drawPath(
      fillPath,
      Paint()..color = AppColors.accent.withValues(alpha: 0.12),
    );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.values != values;
}
