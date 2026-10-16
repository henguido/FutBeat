# Android QA 66 — candidata local 1.0.0+5

Fecha local: 16 de octubre de 2026. Todo el trabajo se hizo en `codex/android-1.0.0-plus-5-feed-62`; no se modificó la versión 1.0.0+4 publicada ni el backend.

## Dispositivo y artefactos

- Único dispositivo conectado: Galaxy A32 `SM-A325M`, serial `RF8R32GQWGL`. El S25 Ultra no se utilizó.
- Instalación original conservada: `com.futbeat.futbeat`, versionCode 4, firma Play SHA-256 `D3:07:B7:E2:F9:D3:99:FA:3C:6C:C3:14:B6:DE:B0:01:39:B3:F6:09:A9:6B:87:EB:FB:76:48:12:D1:0D:CD:E4`. No se abrió, desinstaló ni limpiaron sus datos.
- Instalación de prueba paralela: `com.futbeat.futbeat.qa`, versionCode 5, nombre «FutBeat QA», firma debug SHA-256 `65:33:B8:20:F5:8E:E8:37:E6:BB:ED:B2:9F:09:B2:6A:83:84:76:0E:E3:DE:13:C5:CB:61:85:AD:11:4C:03:62`. APK local `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`, SHA-256 `281ED75B979E52613430EB4CF1E5F2AF259DFA2A7361B0497A26AB6BB2B17DCA`, 187681746 bytes.
- Build QA explícita: demo `true`, Google/Facebook/Push/test ads `false`, sin IDs de anuncios ni productos Premium. El manifiesto QA usa `qa.invalid` y esquema `com.futbeat.futbeat.qa`, no los enlaces de la app Play. Esta variante NO valida OAuth o App Links de producción.

## QA físico comprobado

- La APK QA se instaló lado a lado sin borrar datos de la app Play. Onboarding «Continuar como invitado» y pantalla Partidos se abrieron sin crash.
- En datos demo se siguieron Alajuelense y Real Madrid, más Liga Promerica y UEFA Champions League. Favoritos mostró 2 equipos y 2 competiciones. Chelsea y La Liga España no están en este fixture demo: NOT VERIFIED físicamente.
- Una sola cabecera superior «FAVORITOS». Los encuentros seguidos se mostraron en ella y en sus competiciones. La tarjeta Real Madrid–Arsenal abrió Match Center desde ambos sitios. La igualdad del ID canónico está cubierta por test widget; ADB solo demuestra la misma pantalla visible.
- Tras `force-stop` exclusivamente de la app QA, los favoritos y el grupo persistieron. `am start -W` informó arranque frío de 6803 ms; es una medición debug única, sin baseline comparable.
- `En vivo` dejó solo Saprissa–Alajuelense, una vez por grupo. `Finalizados` mostró un estado vacío correcto para hoy y Cartaginés–Saprissa 0–1 al seleccionar ayer. Se restauró Hoy/Todos.
- Modo avión: estado inicial 0/Wi-Fi 1; durante la prueba, el feed demo y Favoritos continuaron visibles. Estado final restaurado 0/Wi-Fi 1.
- Match Center demo LIVE mostró marcador 2–1, goleadores, estadísticas y tabla de ejemplo con ambos equipos resaltados. Los fixtures inspeccionados no tenían alineaciones; se mostró «Todavía no hay alineaciones disponibles». Titulares, suplentes, formación y entrenador: NOT VERIFIED físicamente.
- Logs filtrados del proceso QA: 0 marcadores de crash/ANR en las últimas 600 entradas inspeccionadas. PSS observado: 340225 KiB; una sola muestra debug, sin conclusión de regresión de memoria.

## Correcciones locales verificadas

- El feed deduplica antes de aplicar estados y conserva la evidencia más fuerte incluso cuando llegan dos revisiones con el mismo ID. Regresiones sintéticas: SCHEDULED/VERIFIED y LIVE/VERIFIED.
- Match Center rechaza una tabla única de temporada diferente a la del partido, en vez de mostrar clasificación equivocada.
- El perfil de jugador resuelve el redirect explícito de su equipo actual antes de buscar partidos.
- `pubspec.yaml` declara 1.0.0+5 solo en esta línea local. No se generó AAB ni release Play.

## Pendientes y límites

- No hubo ventana de backend para QA con datos reales. Roma–Real Madrid 3–4 y Alajuelense–Herediano 1–1, alineaciones reales, Realtime, OAuth y App Links de Play: NOT VERIFIED en esta sesión.
- La pestaña de un jugador usa el calendario de su equipo actual, no apariciones verificadas; club y selección simultáneos requieren un contrato de participaciones del backend. No inferirlas por nombre.
- Dos partidos programados de los mismos equipos y competición a menos de tres horas podrían ser deduplicados como gemelos. Requiere evidencia para distinguir doble jornada legítima de horario corregido; no se cambió esa regla sin datos.
- La APK QA side-by-side no sustituye QA de una futura build firmada/distribuida por Play. La medición de rendimiento no es comparable con 1.0.0+4 release.

No se hicieron consultas a Supabase, GOAL ni proveedores; no hubo despliegue, push, PR, AAB, cambios en Play o pérdida de datos de la app original.
