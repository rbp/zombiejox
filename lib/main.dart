import 'package:flutter/material.dart';

import 'screens/scan_screen.dart';

void main() {
  runApp(const ZombieJoxApp());
}

class ZombieJoxApp extends StatelessWidget {
  const ZombieJoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZombieJox',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ScanScreen(),
    );
  }
}
