# FutBeat

**El latido del fútbol.** Primer incremento nativo Android/iOS, guiado por las historias y arquitectura del proyecto. Costa Rica primero.

## Qué funciona

- Cinco secciones: Partidos, Noticias, Explorar, Favoritos y Perfil.
- Partidos por competición, cambio de fecha, filtros y hora local.
- Match Center con eventos, estadísticas y acceso a equipos, jugadores y competición.
- Perfiles, calendario, participantes/plantilla de ejemplo y tabla de posiciones.
- Buscar nombres y alias (LDA, Sapri).
- Seguir/dejar de seguir equipos, jugadores, competiciones y partidos con SQLite persistente.
- Carga, error con reintento, rutas desconocidas y estados sin datos.

**La app arranca en modo demo sin credenciales. Los partidos, eventos y tabla son ficticios.** Noticias, fichajes y alineaciones todavía muestran estados sin datos. No hay ingesta deportiva ni notificaciones en producción.

## Ejecutar

Requisitos: Flutter **3.47.4**, Dart **3.13.3**, Android SDK/JDK y un emulador o teléfono Android. El lockfile está versionado. iOS requiere macOS/Xcode.

```sh
cd apps/mobile
flutter pub get
dart run build_runner build
flutter run
```

La demo tiene como fecha de referencia el 15/09/2026. Los datos se incluyen como asset y no dependen de red. Los favoritos permanecen en el dispositivo entre sesiones.

En la carpeta local preparada para este proyecto también puedes usar `./scripts/mobile.ps1 run` o `./scripts/mobile.ps1 build apk --debug`: el script encuentra el SDK descargado, aunque Flutter todavía no esté en el PATH. El ajuste local de certificados Java, si existe, se aplica solo al proceso y nunca se sube al repositorio.

### API local opcional

Desde la raíz del repositorio, con Node 22 o superior:

```sh
node backend/api/server.mjs
```

La API escucha en `127.0.0.1:8787`. En Android conectado por ADB:

```sh
adb reverse tcp:8787 tcp:8787
cd apps/mobile
flutter run --dart-define=FUTBEAT_API_URL=http://127.0.0.1:8787
```

HTTP local está permitido solo en la variante debug. Una API de producción debe usar HTTPS. El cliente usa Dio y muestra errores de conexión; no reemplaza una API fallida por resultados demo silenciosamente.

## Verificar

```sh
npm ci
node --test backend/test/*.test.mjs
cd apps/mobile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

Las capturas de referencia se generaron en Windows con zona Costa Rica y fuentes incluidas. Para otras plataformas, ejecutar las pruebas funcionales por archivo (`domain_test.dart`, `database_test.dart`, `flow_test.dart`); diferencias de rasterización pueden afectar las comparaciones visuales. No actualizar goldens sin revisar las imágenes.

CI en GitHub ejecuta validación del contrato, análisis, pruebas y compilación Android, y adjunta el APK de desarrollo cuando termina correctamente. No se publica ninguna app en tiendas.

## Estructura

```text
apps/mobile/             Flutter, Riverpod, GoRouter, Dio, Drift
backend/api/             API de snapshot demo
backend/providers/core/  Validación del grafo y procedencia
backend/automation/      Política de frecuencia y almacén demo
backend/test/            Contratos, atomicidad e idempotencia
packages/contracts/     Fixture compartido y documentación
scripts/                 Sincronización del fixture
docs/                    Arquitectura, trazabilidad, verificaciones
```

- [Arquitectura y comparación inicial](docs/ARCHITECTURE.md)
- [Historias → implementación → pruebas](docs/TRACEABILITY.md)
- [Resultados y límites de verificación](docs/VERIFICATION.md)
- [Contrato de datos](packages/contracts/README.md)

El bloque 0.2 añade el proveedor TheSportsDB y persistencia local. El bloque 0.3 conecta la lectura remota en Supabase y un APK mediante HTTPS. Consulta [datos locales](docs/DATA-BLOCK.md) y [conexión en la nube](docs/CLOUD.md). La demo continúa siendo el modo predeterminado al compilar sin configuración; ingesta automática y tabla LIVE siguen pendientes.
