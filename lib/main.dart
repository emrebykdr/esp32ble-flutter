import 'package:flutter/material.dart';
import 'core/app_colors.dart';
import 'home_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ESP32 BLE',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          surface: AppColors.card,
          onSurface: AppColors.textPrimary,
        ),
        // Kart görünümü (ör. BLE cihaz listesi)
        cardTheme: CardThemeData(
          color: AppColors.card,
          elevation: 0,
          margin: const EdgeInsets.symmetric(vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: AppColors.cardBorder, width: 1),
          ),
        ),
        // Switch rengi (ör. bağlantı durumu)
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? AppColors.accent
                : AppColors.textMuted,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? AppColors.accent.withValues(alpha: 0.3)
                : AppColors.switchTrack,
          ),
          trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
