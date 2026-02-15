import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/serial_provider.dart';
import 'screens/flash_tool_screen.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SerialProvider(),
      child: MaterialApp(
        title: 'EasyGUI Flash Tool',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepOrange,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const FlashToolScreen(),
      ),
    );
  }
}
