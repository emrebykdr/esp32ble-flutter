import 'package:flutter/material.dart';

class Responsive {
  final double width;
  final double height;

  Responsive(BuildContext context)
    : width = MediaQuery.of(context).size.width,
      height = MediaQuery.of(context).size.height;

  bool get isSmall => width < 360;
  bool get isLarge => width > 414;

  double get horizontalPadding => isSmall ? 12 : 16;
  double get cardPadding => isSmall ? 12 : 16;

  double scale(double value) => value * (width / 390);
}
