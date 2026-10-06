import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'profile_section.dart';

class SupportLegalScreen extends StatelessWidget {
  const SupportLegalScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Soporte y legal')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        ProfileSection(
          title: 'Soporte',
          children: [
            _CopyTile(
              icon: Icons.mail_outline,
              title: 'Contactar soporte',
              value: 'support@futbeat.com',
            ),
          ],
        ),
        ProfileSection(
          title: 'Legal',
          children: const [
            _CopyTile(
              icon: Icons.privacy_tip_outlined,
              title: 'Política de privacidad',
              value: 'https://futbeat.com/privacy',
            ),
            _CopyTile(
              icon: Icons.description_outlined,
              title: 'Términos',
              value: 'https://futbeat.com/terms',
            ),
            _CopyTile(
              icon: Icons.delete_outline,
              title: 'Información de eliminación',
              value: 'https://futbeat.com/data-deletion',
            ),
          ],
        ),
      ],
    ),
  );
}

class _CopyTile extends StatelessWidget {
  const _CopyTile({
    required this.icon,
    required this.title,
    required this.value,
  });
  final IconData icon;
  final String title;
  final String value;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: Text(value),
    trailing: const Icon(Icons.copy_outlined),
    onTap: () async {
      await Clipboard.setData(ClipboardData(text: value));
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Copiado.')));
      }
    },
  );
}
