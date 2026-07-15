import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ble_service.dart';
import 'ble_device_model.dart';
import 'core/app_colors.dart';
import 'core/app_responsive.dart';

// Ana ekran: cihaz tarama, bağlanma, LED/röle kontrolü, sensör verisi ve
// mesafe alarmı akışlarının tamamı burada yönetiliyor.
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

  // Mesafe alarmı: belirlenen [min, max] aralığına girince yanıp sönen
  // görsel uyarı + beep sesi tetiklenir
  final AudioPlayer _alarmPlayer = AudioPlayer();
  // late final: sadece ilk kullanımda bir kez üretilir, her rebuild'de tekrar hesaplanmaz
  late final Uint8List _beepWav = _generateBeepWav();
  bool _alarmEnabled = false;
  int? _alarmMinCm;
  int? _alarmMaxCm;
  bool _alarmBlinkOn = false;
  Timer? _alarmTimer;

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
          _stopAlarm();
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
        _evaluateAlarm(distance);
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

  // Mesafe [min, max] aralığına girip girmediğini kontrol eder;
  // girdiyse yanıp sönen görsel uyarıyı ve beep'i başlatır
  void _evaluateAlarm(int distance) {
    final validRange = _alarmMinCm != null &&
        _alarmMaxCm != null &&
        _alarmMinCm! <= _alarmMaxCm!;
    final inRange = _alarmEnabled &&
        validRange &&
        distance >= _alarmMinCm! &&
        distance <= _alarmMaxCm!;

    // _alarmTimer == null kontrolü: aralıkta kaldığı sürece her okumada
    // (yaklaşık 500ms'de bir) yeni bir timer başlatılmasını, yani beep'in
    // olduğundan daha sık çalmasını engelliyor — timer zaten çalışıyorsa dokunma.
    if (inRange && _alarmTimer == null) {
      _playBeep();
      _alarmBlinkOn = true;
      _alarmTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (!mounted) return;
        setState(() => _alarmBlinkOn = !_alarmBlinkOn);
        _playBeep();
      });
    } else if (!inRange) {
      _stopAlarm();
    }
  }

  // Alarm timer'ını durdurur ve görsel yanıp sönmeyi kapatır;
  // mesafe aralıktan çıkınca, bağlantı kesilince veya alarm kapatılınca çağrılır
  void _stopAlarm() {
    _alarmTimer?.cancel();
    _alarmTimer = null;
    _alarmBlinkOn = false;
  }

  // Bellekte üretilen WAV byte'larını doğrudan çalar, disk/asset gerekmez
  void _playBeep() {
    _alarmPlayer.play(BytesSource(_beepWav));
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
    _alarmTimer?.cancel();
    _alarmPlayer.dispose();
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
                  alarmEnabled: _alarmEnabled,
                  alarmMin: _alarmMinCm,
                  alarmMax: _alarmMaxCm,
                  alarmBlinking: _alarmBlinkOn,
                  onAlarmSettingsChanged: (enabled, min, max) {
                    setState(() {
                      _alarmEnabled = enabled;
                      _alarmMinCm = min;
                      _alarmMaxCm = max;
                      if (!enabled) _stopAlarm();
                    });
                  },
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

  final bool alarmEnabled;
  final int? alarmMin;
  final int? alarmMax;
  final bool alarmBlinking; // true iken mesafe alarm aralığında, yanıp sönme aktif
  final void Function(bool enabled, int? min, int? max) onAlarmSettingsChanged;

  const _SensorCard({
    required this.distanceCm,
    this.history = const [],
    this.isStale = false,
    required this.alarmEnabled,
    required this.alarmMin,
    required this.alarmMax,
    required this.alarmBlinking,
    required this.onAlarmSettingsChanged,
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

  // Alarm aralığını (min/max cm) ve açık/kapalı durumunu ayarlamak için diyalog
  Future<void> _showAlarmDialog(BuildContext context) async {
    final minController = TextEditingController(text: widget.alarmMin?.toString() ?? '');
    final maxController = TextEditingController(text: widget.alarmMax?.toString() ?? '');
    var enabled = widget.alarmEnabled;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.card,
              title: const Text('Mesafe Alarmı', style: TextStyle(color: AppColors.textPrimary)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Alarmı Etkinleştir',
                      style: TextStyle(color: AppColors.textPrimary, fontSize: 14),
                    ),
                    value: enabled,
                    activeThumbColor: Colors.amber,
                    onChanged: (v) => setDialogState(() => enabled = v),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: minController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: AppColors.textPrimary),
                          decoration: const InputDecoration(labelText: 'Min (cm)'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: maxController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: AppColors.textPrimary),
                          decoration: const InputDecoration(labelText: 'Max (cm)'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('İptal'),
                ),
                TextButton(
                  onPressed: () {
                    widget.onAlarmSettingsChanged(
                      enabled,
                      int.tryParse(minController.text),
                      int.tryParse(maxController.text),
                    );
                    Navigator.pop(dialogContext);
                  },
                  child: const Text('Kaydet'),
                ),
              ],
            );
          },
        );
      },
    );
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
                Row(
                  children: [
                    // Mesafe alarmı ayarları — açık/kapalı ve aralık burada belirlenir
                    IconButton(
                      onPressed: () => _showAlarmDialog(context),
                      icon: Icon(
                        widget.alarmEnabled
                            ? Icons.notifications_active
                            : Icons.notifications_none,
                        size: 18,
                        color: widget.alarmEnabled
                            ? Colors.amber
                            : AppColors.textMuted,
                      ),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    const SizedBox(width: 4),
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
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  widget.distanceCm != null ? '${widget.distanceCm} cm' : '--',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (widget.alarmBlinking) ...[
                  const SizedBox(width: 10),
                  const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 24),
                ],
              ],
            ),
            if (widget.alarmEnabled && widget.alarmMin != null && widget.alarmMax != null) ...[
              const SizedBox(height: 2),
              Text(
                'Alarm: ${widget.alarmMin}-${widget.alarmMax} cm',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
            ],
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

// Mesafe alarmı için kısa bir beep sesi (WAV, PCM16 mono) üretir.
// Harici ses dosyası eklemekten kaçınmak için ton kod içinde sentezleniyor.
Uint8List _generateBeepWav({
  int freq = 1000,
  int durationMs = 150,
  int sampleRate = 8000,
}) {
  final numSamples = (sampleRate * durationMs / 1000).round();
  final pcm = ByteData(numSamples * 2);
  for (var i = 0; i < numSamples; i++) {
    final t = i / sampleRate;
    final sample = (sin(2 * pi * freq * t) * 32767 * 0.6).round();
    pcm.setInt16(i * 2, sample, Endian.little);
  }
  final pcmBytes = pcm.buffer.asUint8List();

  final header = BytesBuilder();
  void writeString(String s) => header.add(s.codeUnits);
  void writeUint32(int v) => header.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  void writeUint16(int v) => header.add([v & 0xff, (v >> 8) & 0xff]);

  writeString('RIFF');
  writeUint32(36 + pcmBytes.length);
  writeString('WAVE');
  writeString('fmt ');
  writeUint32(16);
  writeUint16(1); // PCM
  writeUint16(1); // mono
  writeUint32(sampleRate);
  writeUint32(sampleRate * 2); // byte rate
  writeUint16(2); // block align
  writeUint16(16); // bits per sample
  writeString('data');
  writeUint32(pcmBytes.length);

  final result = BytesBuilder();
  result.add(header.toBytes());
  result.add(pcmBytes);
  return result.toBytes();
}
