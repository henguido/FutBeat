import 'package:flutter/material.dart';

import 'ads_privacy_tile.dart';
import 'profile_section.dart';

class PrivacyAdsScreen extends StatelessWidget {
  const PrivacyAdsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Privacidad y anuncios')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: const [
        ProfileSection(
          title: 'Anuncios',
          children: [
            ListTile(
              leading: Icon(Icons.campaign_outlined),
              title: Text('Anuncios en FutBeat'),
              subtitle: Text(
                'El plan Gratis puede mostrar anuncios. Premium elimina los anuncios.',
              ),
            ),
            AdsPrivacyOptionsTile(),
          ],
        ),
        ProfileSection(
          title: 'Privacidad',
          children: [
            ListTile(
              leading: Icon(Icons.privacy_tip_outlined),
              title: Text('Política de privacidad'),
              subtitle: SelectableText('https://futbeat.com/privacy'),
            ),
          ],
        ),
      ],
    ),
  );
}
