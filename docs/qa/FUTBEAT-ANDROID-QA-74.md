# Android QA 74 — candidata local 1.0.0+5

Fecha: 18 de octubre de 2026. Rama `codex/android-1.0.0-plus-5-feed-62`, base `b208924`, HEAD funcional `7e48df0`. Tres agentes hicieron revisiones locales de feed, Match Center e identidad; el integrador revisó y aplicó los cambios. No hubo acceso a Supabase ni a GOAL.

## Correcciones locales

| Commit | Defecto demostrado | Corrección y regresión |
| --- | --- | --- |
| `203559e` | Dos filas finales del mismo ID dejaban un marcador viejo en el feed mientras `Snapshot.match` usaba el nuevo. | Para igual fuerza, conservar la última fila canónica en el feed. Test unitario y widget para Favoritos y competición; el test unitario falló antes del fix. |
| `2093db4` | `Snapshot.forMatch` descartaba un asistente cuyo club actual no participaba en el partido. | Retener `assistPlayerId` de eventos presentados y originales. Fixture de un club externo; falló antes del fix. |
| `7e48df0` | Dos alias con redirect explícito al mismo jugador canónico ausente aparecían dos veces en la plantilla. | Conservar un representante del ID canónico ausente, sin fusionar por nombre. Test widget; falló antes del fix. |

Las pruebas focales relevantes pasaron (122 para feed/identidad/Match Center y 68 para plantilla/perfiles). La suite final completa pasó con **1.244 pruebas aprobadas, una omitida y cero fallos**. `flutter analyze --no-pub` y `git diff --check` quedaron limpios. No se cambiaron contratos backend.

## A32 y artefacto final

- Único teléfono usado: Galaxy A32 `SM-A325M`, serial `RF8R32GQWGL`; no se usó el S25 Ultra.
- La app oficial `com.futbeat.futbeat` permanece instalada en versionCode 4; no se abrió ni se limpiaron sus datos.
- La variante independiente `com.futbeat.futbeat.qa` fue instalada/actualizada con `adb install -r`, versionCode 5, versión 1.0.0, firma debug SHA-256 `65:33:B8:20:F5:8E:E8:37:E6:BB:ED:B2:9F:09:B2:6A:83:84:76:0E:E3:DE:13:C5:CB:61:85:AD:11:4C:03:62`.
- APK final: `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`; SHA-256 `C181B3A3A0F707CA096952D0A4EB483D11F17DB83702AF5D170C5837501EDEBC`; 187681746 bytes. Build debug explícita con demo=true, Google/Facebook/Push/test ads=false y paquete QA opt-in. No es un AAB ni una build de Play.
- La variante QA estaba ausente al iniciar esta sesión; se reinstaló sin tocar la app oficial. El favorito de Alajuelense creado después persistió a través de `force-stop` y `install -r`.

## QA físico observado

- Arranque y feed demo sin crash. Un solo grupo «FAVORITOS»; Saprissa–Alajuelense apareció una vez allí y otra en Liga Promerica. Tras reiniciar, reapareció cuando terminó el primer render.
- Match Center demo LIVE mostró 2–1, 72′, goleadores y tabla de cuatro posiciones con ambos equipos resaltados. Alineación indicó correctamente que no había datos disponibles.
- Desde Match Center se abrió el perfil de Alajuelense; se siguió el equipo y se navegó desde Plantilla al perfil ficticio de Joel Campbell.
- Modo avión breve: Match Center demo permaneció visible; estado restaurado a avión=0 y Wi-Fi=1.
- Arranques fríos debug observados: 8813, 5650 y 7949 ms. No existe una medición release comparable; no se atribuye mejora ni regresión de rendimiento. Último proceso QA: cero marcadores de crash/ANR en logs de error filtrados.

## Pendiente / handoff

- **Claude:** C1 sigue bajo observación y Supabase supera el límite Free. No iniciar QA real sin una ventana explícita, vigente y acotada. El problema de pertenencia club/selección en ingesta sigue siendo backend; estos fixes solo conservan la identidad visible local.
- No se probaron datos reales, OAuth, App Links, Realtime natural, alineaciones reales, Roma–Real Madrid ni Alajuelense–Herediano. La variante `.qa` tiene esquemas de enlace distintos de la app Play y no valida sus redirects.
- Riesgos que requieren evidencia/política: tabla de un único grupo histórico con fase distinta; goleadores homónimos sin ID en el mismo equipo; orden de revisiones finales duplicadas si un backend entrega una revisión más antigua al final. No se aplicaron fusiones de identidad por nombre.
- Para Play: coordinar primero QA real con Claude, probar Auth/App Links en el paquete firmado correcto, repetir QA físico release y verificar configuración/firma. **GO para revisión local de la candidata; NO-GO para AAB o distribución.**

No hubo push, PR, merge, AAB, Play, migraciones, SQL remoto, cambios a GOAL ni cambios en worktrees de Claude.
