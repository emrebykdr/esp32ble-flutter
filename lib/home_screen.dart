import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_service.dart';
import 'ble_device_model.dart';
import 'core/app_colors.dart';
import 'core/app_responsive.dart';

// Ana ekran: cihaz tarama ve bağlanma akışını yönetir.
// LED/röle kontrolü ve sensör verisi kısmı henüz eklenmedi.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final BleService _bleService = BleService();

  static const int _maxHistoryLength = 40;
  // Bu süre boyunca yeni sensör okuması gelmezse veri "bayat" sayılır
  // (ESP32 her ~500ms'de bir gönderiyor, 2sn ~4 kaçırılan tura karşılık gelir)
  static const Duration _staleThreshold = Duration(seconds: 2);

  List<BleDeviceModel> _devices = [];
  bool _isScanning = false;
  bool _isConnecting = false;
  bool _isConnected = false;
  int? _distance;
  final List<int> _distanceHistory = [];
  DateTime? _lastSensorUpdate;
  bool _isSensorStale = false;
  Timer? _staleCheckTimer;
  String _connectedName = '';

  bool _redLed = false;
  bool _greenLed = false;
  bool _blueLed = false;
  bool _relay = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _listenStreams();
    _staleCheckTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_lastSensorUpdate == null || !_isConnected) return;
      final isStale = DateTime.now().difference(_lastSensorUpdate!) > _staleThreshold;
      if (isStale != _isSensorStale) {
        setState(() => _isSensorStale = isStale);
      }
    });
  }

  // Android BLE için gerekli izinleri ister
  Future<void> _requestPermissions() async {
    if (kIsWeb) return;
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.locationWhenInUse.request();
  }

  // BleService stream'lerini dinler ve state'i günceller
  void _listenStreams() {
    _bleService.devicesStream.listen((devices) {
      setState(() => _devices = devices);
    });

    _bleService.connectionStream.listen((connected) {
      setState(() {
        _isConnected = connected;
        if (!connected) {
          _redLed = false;
          _greenLed = false;
          _blueLed = false;
          _relay = false;
          _distance = null;
          _distanceHistory.clear();
          _lastSensorUpdate = null;
          _isSensorStale = false;
        }
      });
    });
    _bleService.sensorStream.listen((distance) {
      setState(() {
        _distance = distance;
        _distanceHistory.add(distance);
        if (_distanceHistory.length > _maxHistoryLength) {
          _distanceHistory.removeAt(0);
        }
        _lastSensorUpdate = DateTime.now();
        _isSensorStale = false;
      });
    });

    _bleService.errorStream.listen((message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    });
  }

  // Tarama butonuna basılınca çağrılır
  Future<void> _toggleScan() async {
    if (_isScanning) {
      await _bleService.stopScan();
      setState(() => _isScanning = false);
    } else {
      setState(() => _isScanning = true);
      try {
        await _bleService.startScan();
      } catch (e) {
        debugPrint('Tarama hatası: $e');
      } finally {
        setState(() => _isScanning = false);
      }
    }
  }

  // Listeden cihaz seçilince bağlantı kurar
  Future<void> _connectToDevice(BleDeviceModel device) async {
    setState(() => _isConnecting = true);
    try {
      await _bleService.connect(device);
      setState(() => _connectedName = device.name);
    } catch (e) {
      debugPrint('Bağlantı hatası: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${device.name} cihazına bağlanılamadı')),
        );
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> _disconnect() async {
    // Bağlantı kesilmeden önce açık LED/röle varsa kapat, aksi halde donanımda yanık kalır
    if (_redLed) await _bleService.sendCommand(BleService.redLedOff);
    if (_greenLed) await _bleService.sendCommand(BleService.greenLedOff);
    if (_blueLed) await _bleService.sendCommand(BleService.blueLedOff);
    if (_relay) await _bleService.sendCommand(BleService.relayOff);

    await _bleService.disconnect();
    setState(() => _connectedName = '');
  }

  @override
  void dispose() {
    _staleCheckTimer?.cancel();
    _bleService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = Responsive(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: r.horizontalPadding,
            vertical: 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 16),

              _ScanButton(isScanning: _isScanning, onPressed: _toggleScan),
              const SizedBox(height: 8),

              // Bulunan cihazlar listesi — cihaz varsa göster
              if (_devices.isNotEmpty)
                _DeviceList(
                  devices: _devices,
                  isConnecting: _isConnecting,
                  onDeviceTap: _connectToDevice,
                ),

              // Bağlı cihaz kartı — bağlıysa göster
              if (_isConnected) ...[
                const SizedBox(height: 8),
                _ConnectedCard(
                  deviceName: _connectedName,
                  onDisconnect: _disconnect,
                ),
                const SizedBox(height: 8),
                _LedRelayCard(
                  redLed: _redLed,
                  greenLed: _greenLed,
                  blueLed: _blueLed,
                  relay: _relay,
                  onRedChanged: (v) {
                    setState(() => _redLed = v);
                    _bleService.sendCommand(
                      v ? BleService.redLedOn : BleService.redLedOff,
                    );
                  },
                  onGreenChanged: (v) {
                    setState(() => _greenLed = v);
                    _bleService.sendCommand(
                      v ? BleService.greenLedOn : BleService.greenLedOff,
                    );
                  },
                  onBlueChanged: (v) {
                    setState(() => _blueLed = v);
                    _bleService.sendCommand(
                      v ? BleService.blueLedOn : BleService.blueLedOff,
                    );
                  },
                  onRelayChanged: (v) {
                    setState(() => _relay = v);
                    _bleService.sendCommand(
                      v ? BleService.relayOn : BleService.relayOff,
                    );
                  },
                ),
                const SizedBox(height: 8),
                _SensorCard(
                  distanceCm: _distance,
                  history: _distanceHistory,
                  isStale: _isSensorStale,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // Ekran üst başlığı — ESP32 / BLE Controller + bağlantı durumu nokta
  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ESP32',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'BLE Controller',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ],
        ),
        // Yeşil: bağlı, gri: bağlı değil
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _isConnected ? AppColors.accent : AppColors.textMuted,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tarama başlat/durdur butonu
// ---------------------------------------------------------------------------
class _ScanButton extends StatefulWidget {
  final bool isScanning; // Şu an tarama yapılıyor mu
  final VoidCallback onPressed; // Butona basılınca çağrılır

  const _ScanButton({
    required this.isScanning,
    required this.onPressed,
  });

  @override
  State<_ScanButton> createState() => _ScanButtonState();
}

class _ScanButtonState extends State<_ScanButton>
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
  void didUpdateWidget(covariant _ScanButton oldWidget) {
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

// ---------------------------------------------------------------------------
// Taramada bulunan cihazların listesi
// ---------------------------------------------------------------------------
class _DeviceList extends StatelessWidget {
  final List<BleDeviceModel> devices; // Bulunan cihazlar
  final Function(BleDeviceModel) onDeviceTap; // Listeden bir cihaza dokununca çağrılır
  final bool isConnecting; // true iken taplar devre dışı, yükleniyor göstergesi çıkar

  const _DeviceList({
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

// ---------------------------------------------------------------------------
// Bağlı cihazı ve bağlantı kesme butonunu gösteren kart
// ---------------------------------------------------------------------------
class _ConnectedCard extends StatelessWidget {
  final String deviceName; // Bağlı cihazın adı
  final VoidCallback onDisconnect; // "Kes" butonuna basılınca çağrılır

  const _ConnectedCard({
    required this.deviceName,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  deviceName,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Bağlı',
                  style: TextStyle(
                    color: AppColors.accent,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            // Bağlantıyı kesme butonu
            OutlinedButton.icon(
              onPressed: onDisconnect,
              icon: const Icon(Icons.bluetooth_disabled, size: 16),
              label: const Text('Kes'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                side: const BorderSide(color: AppColors.cardBorder),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LED (kırmızı/yeşil/mavi) ve röle switch'lerini gösteren kart
// ---------------------------------------------------------------------------
class _LedRelayCard extends StatelessWidget {
  final bool redLed;
  final bool greenLed;
  final bool blueLed;
  final bool relay;

  final Function(bool) onRedChanged;
  final Function(bool) onGreenChanged;
  final Function(bool) onBlueChanged;
  final Function(bool) onRelayChanged;

  const _LedRelayCard({
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

// ---------------------------------------------------------------------------
// Mesafe sensörü (HC-SR04) değerini gösteren kart.
// Sağ üstteki grafik butonuyla son okumaların trendini gösteren
// basit bir çizgi grafik açılıp kapanabilir.
// ---------------------------------------------------------------------------
class _SensorCard extends StatefulWidget {
  final int? distanceCm;
  final List<int> history;
  final bool isStale; // true iken bir süredir yeni okuma gelmemiş demektir

  const _SensorCard({
    required this.distanceCm,
    this.history = const [],
    this.isStale = false,
  });

  @override
  State<_SensorCard> createState() => _SensorCardState();
}

class _SensorCardState extends State<_SensorCard>
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
  void didUpdateWidget(covariant _SensorCard oldWidget) {
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
