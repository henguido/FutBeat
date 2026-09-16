# Verificación

## Bloque 0.2 — 16 septiembre 2026 UTC

- 9 pruebas backend: contrato, persistencia tras reinicio, identidad estable,
  idempotencia, rollback, ventanas parciales, errores HTTP, orden temporal y
  rechazo de lectura SQL por un rol sin privilegios.
- 19 pruebas móviles aprobadas, incluidas las 4 comparaciones visuales originales
  y el nuevo flujo de cobertura parcial/antigüedad/fechas disponibles.
- Prueba adicional real aprobada: `FUTBEAT_VERIFY_URL=http://127.0.0.1:8787`
  con `flutter test test/api_repository_test.dart` leyó los datos guardados desde
  Dio y comprobó equipos, partidos, fuente y estado provisional.
- Importación oficial real: 2 partidos, 4 equipos; lote recibido
  `2026-09-16T02:36:22.347Z`. No se infiere exactitud deportiva de esta prueba.
- Análisis Flutter sin incidencias y APK Android debug compilado.
- SHA-256 APK de este bloque:
  `0499C2C04B8AE063A4DD8607766AA6B8042619CC621C14322BE0F9FD82844B5A`.

El APK predeterminado sigue en demo. [Instrucciones para conectarlo a la API local](DATA-BLOCK.md).
No se probó este APK nuevo en teléfono físico ni se compiló iOS. Supabase remoto
no está conectado: el proyecto facilitado devolvió un error de permisos. La
migración se verificó en PGlite, no en la plataforma Supabase completa. No hay
actualización automática ni datos LIVE en este bloque.

## Registro del incremento inicial · 15 septiembre 2026

## Entorno

- Windows 11, Flutter 3.47.4, Dart 3.13.3.
- Dependencias móviles resueltas y conservadas en `pubspec.lock`.
- Android: proyecto nativo generado, NDK 28.2.13676358, plataformas SDK 35/36 y CMake 3.22.1 instalados durante la compilación usando las licencias existentes.
- El antivirus interceptaba TLS para Java. Se utilizó una copia local del almacén de Java con el certificado AVG ya confiado por Windows. No se desactivó la validación ni se cambió el almacén global. Los archivos están fuera del repo, en `.tools/` de la carpeta superior.

## Resultados

| Comprobación | Resultado |
|---|---|
| Backend y contrato compartido | 6 pruebas aprobadas |
| Dominio móvil | 5 pruebas aprobadas |
| Persistencia SQLite tras cerrar/reabrir | 1 prueba aprobada |
| Cliente Dio sobre HTTP local y error 503 | 1 prueba aprobada |
| Navegación, búsqueda, fechas, reintento, seguimiento UI y diseño a 360 px/1.4× texto | 7 pruebas aprobadas |
| Capturas de Partidos, Match Center, competición y Explorar | 4 capturas generadas y revisadas |
| Análisis Flutter | Sin incidencias |
| Android debug APK | Compilación correcta; archivo de 171.267.618 bytes |
| Script local `scripts/mobile.ps1 --version` | SDK localizado y ejecutado correctamente |

El APK está en `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`. Es un build de desarrollo; no está publicado ni firmado para distribución en tiendas. Los binarios y cachés se excluyen de Git. GitHub Actions compila otro APK desde los fuentes al ejecutar el workflow.

Metadatos del APK comprobados con Android aapt: `com.futbeat.futbeat`, versión `0.1.0` (1), nombre FutBeat, Android mínimo API 24 y objetivo API 36. SHA-256: `35761E773CD46A64A31BA3B312CE12754131DBC3ACBFA34F8F4B4612667ED35E`.

## Problemas detectados y resueltos

- Error de sintaxis al leer una imagen opcional.
- Búsqueda LDA: se agregó la abreviatura al índice junto con nombre y alias.
- Fuentes e iconos ausentes en las capturas de pruebas: se cargan explícitamente para comparaciones legibles.
- La prueba UI de seguimiento seleccionaba una estrella de partido; ahora identifica la estrella del AppBar del equipo y verifica su aparición en Favoritos con SQLite real.
- Errores al refrescar: se presentan mediante el estado de error y Reintentar, sin propagarlos fuera de la UI.
- TLS de Gradle: corregido con confianza local en el certificado del entorno.

## Límites de la verificación

- No había un teléfono o emulador Android conectado: se verificaron compilación APK y widgets mediante el motor de pruebas Flutter, no una sesión instalada en dispositivo físico.
- iOS tiene estructura generada, pero no se compiló en Windows.
- Datos ficticios, tabla estática y seguimiento local. No se verificaron proveedores reales, Supabase, push, licencias de escudos, noticias ni transferencias.
- Las capturas siguen composición, paleta y navegación del mockup; usan iniciales en lugar de escudos sin fuente autorizada y aún no incluyen la fotografía de portada.
- El workflow de GitHub queda configurado; su resultado remoto debe consultarse en Actions y no se infiere de la validación local.
