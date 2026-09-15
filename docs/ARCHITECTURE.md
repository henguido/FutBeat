# FutBeat · arquitectura implementada, incremento 0.1

## Fuentes obligatorias

- `reference/ARCHITECTURE-v1.txt`: arquitectura original completa aportada al crear las historias.
- `reference/USER-STORIES-PREVIEW.md`: extracto recuperado de las historias originales; se conserva su numeración. La vista disponible se corta durante FB-US-074.
- Mockup del proyecto: `sources/Imagen de Codex 15 sept 2026, 15_24_34.png` en la carpeta superior. Es referencia de solo lectura.

## Inspección inicial · 15 septiembre 2026

GitHub confirmó `henguido/FutBeat` privado, tamaño 0, sin commits. La carpeta accesible del proyecto contenía AGENTS.md y el mockup; no existían código, stack, tests ni funcionalidad que migrar. Se clonó el repo en `FutBeat/` dentro de esa carpeta, conservando `sources/` intacto.

## Decisiones

| Arquitectura v1 | Incremento 0.1 | Diferido |
|---|---|---|
| Flutter/Dart, Android primero | Flutter 3.47.4 / Dart 3.13.3; proyectos Android/iOS | Compilación y distribución iOS requieren macOS |
| Riverpod, GoRouter, Dio | Inyección de repositorio, estado asíncrono y rutas canónicas | Realtime y caché de respuestas |
| Drift/SQLite | Seguimiento local transaccional y persistente | Cuenta, sincronización y caché deportiva |
| Entity Graph | Partido → competición/equipos → jugadores; IDs `fb_*` | Relaciones de noticias, videos y fichajes |
| API/BFF | API Node local y contrato snapshot v1; Dio puede consumirlo | BFF paginado y despliegue |
| Providers/Automation/Quality | Validación del lote, procedencia, política de frecuencia y deduplicación de jobs en memoria | Proveedor real, almacenamiento durable, bloqueos distribuidos, reintentos y scheduler |
| Supabase/Postgres/Auth/Realtime | Frontera definida, sin crear recursos remotos ni migraciones incompletas | Modelado relacional, RLS y verificación en base local |
| Tabla LIVE/reglas por temporada | Tabla de ejemplo con PJ/G/E/P/GF/GC/DG/PTS, expresamente estática | Cálculo simultáneo, reglas y reconciliación |
| Media Engine | Componente de imágenes verificadas y fallback de iniciales | Obtención de escudos/fotos con fuente y derechos |

## Recorrido de datos

`packages/contracts/demo.snapshot.json` → API de demostración `/v1/snapshot` → `ApiRepository` (Dio) → `Snapshot` → Riverpod → pantallas.

Sin configuración, `DemoRepository` carga la copia del mismo contrato incluida en la app y funciona sin red. No se degrada silenciosamente de API real a demo: una API fallida muestra error y Reintentar. El fixture fija el día de demostración en 15/09/2026; la app identifica todos los resultados como ficticios. Las fechas se almacenan con zona UTC y se muestran en la zona local del dispositivo.

La persistencia del seguimiento es real, local y sin cuenta. No genera notificaciones. La API de ejemplo solo escucha en localhost y no implementa escritura, autentificación, sincronización real ni servicios de terceros.

## Límites deliberados

No se reportan historias AUTO como completadas por tener un contrato o función de ejemplo. No hay datos deportivos en vivo, noticias reales, tabla LIVE, transferencias, fotos licenciadas ni automatización desplegada. Los módulos de referencia aún vacíos no se crean como carpetas ficticias: se añadirán junto con su implementación verificable.

## Documentación técnica consultada

- [Flutter: instalación oficial](https://docs.flutter.dev/install/manual)
- [Drift: configuración y generación de SQLite](https://drift.simonbinder.eu/setup/)
- [Riverpod](https://pub.dev/packages/flutter_riverpod)
- [GoRouter](https://pub.dev/packages/go_router)

Versiones resueltas conservadas en `apps/mobile/pubspec.lock`.
