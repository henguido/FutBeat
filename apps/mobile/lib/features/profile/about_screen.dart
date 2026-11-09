import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'profile_section.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Acerca de FutBeat')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.sports_soccer, size: 58),
        const SizedBox(height: 12),
        const Text(
          'FutBeat',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
        ),
        const Text('El latido del fútbol', textAlign: TextAlign.center),
        ProfileSection(
          title: 'Aplicación',
          children: [
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Versión'),
              trailing: Text('1.0.0'),
            ),
            ListTile(
              leading: const Icon(Icons.public),
              title: const Text('Web'),
              subtitle: const Text('https://futbeat.com'),
              trailing: const Icon(Icons.copy_outlined),
              onTap: () async {
                await Clipboard.setData(
                  const ClipboardData(text: 'https://futbeat.com'),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Enlace copiado.')),
                  );
                }
              },
            ),
          ],
        ),
      ],
    ),
  );
}
