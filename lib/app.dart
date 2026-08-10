import 'package:flutter/material.dart';

import 'features/projects/project_list_screen.dart';
import 'ui/app_theme.dart';

class AvenzaApp extends StatelessWidget {
  const AvenzaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Avenza para Pobres',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const ProjectListScreen(),
    );
  }
}
