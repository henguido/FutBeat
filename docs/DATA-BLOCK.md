# Bloque 0.2: proveedor y persistencia local

## Ejecutar datos reales

Desde la raíz del repositorio, con Node 22 o superior y npm:

```sh
npm ci
npm run data:sync
npm run api:real
```

La primera orden de sincronización consulta tres endpoints oficiales de TheSportsDB
(liga costarricense 4815, próximos y recientes) y guarda un lote completo en
`.local-data/postgres`. Esta carpeta no se versiona. El servidor sirve ese último
lote en `http://127.0.0.1:8787/v1/snapshot`. Sin importación devuelve 503.

PGlite ejecuta PostgreSQL integrado en Node: no requiere Docker. **Solo un proceso
debe abrir esa carpeta a la vez.** Detén la API antes de repetir `data:sync` y
reiníciala después. No hay scheduler activo; refrescar la app vuelve a leer la base,
no consulta al proveedor. No ejecutes importaciones en bucle: cada una consume tres
peticiones; ante errores HTTP, incluido 429, se detiene sin reintentar.

Para usar los datos en Android por USB:

```sh
adb reverse tcp:8787 tcp:8787
cd apps/mobile
flutter run --dart-define=FUTBEAT_API_URL=http://127.0.0.1:8787
```

También se puede compilar con esa misma opción `--dart-define`. El APK normal
continúa en demo sin servidor. La variante conectada necesita la API encendida y
el reenvío ADB activo. HTTP solo se permite en debug; producción requiere HTTPS.

## Qué garantiza este incremento

- IDs internos persistentes y equivalencias explícitas por proveedor/tipo/ID.
- Correspondencias conocidas para competición CR, Cartaginés y Alajuelense;
  otras entidades reciben UUID. No se fusionan equipos por similitud de nombre.
- Lote transaccional: un estado desconocido, referencia inválida o marcador
  incompleto cancela la importación y conserva el último lote válido.
- Jobs idempotentes persistentes y rechazo de importaciones fuera de orden.
- Ventanas parciales no eliminan partidos importados anteriormente.
- Respuesta original y hora de recepción guardadas junto al snapshot.
- Resultados FT quedan pendientes de verificación, nunca verificados por una
  sola fuente. No se fabrican minutos, estadísticas, alineaciones ni tablas.
- Aviso de cobertura parcial, sin directo, y antigüedad del último lote (>6 horas).
  El detalle muestra la recepción propia de cada partido, que puede ser anterior.
- Esquema privado con RLS y sin acceso público directo; solo el BFF lee los datos.

## Alcance y proveedor

La prueba real del 16/09/2026 UTC importó dos partidos y cuatro equipos. Es una
observación de esa consulta, no una garantía de cobertura completa o exactitud.
El plan gratuito puede devolver solo un evento por endpoint. Se usa la clave
pública de desarrollo documentada `123`; no hay secretos en el cliente.

[Documentación TheSportsDB](https://www.thesportsdb.com/documentation) y
[condiciones de uso](https://www.thesportsdb.com/docs_terms_of_use.php): la clave
gratuita se utiliza para desarrollo; la publicación en tiendas requiere revisar
el plan y sus condiciones. No se descargan ni publican escudos del proveedor.

## Supabase

Proyecto indicado: `izlmruqawgagwdcsjhte`. La conexión disponible devolvió un error
de permisos al consultarlo. **No se aplicaron migraciones remotas ni se conectó la
app a ese proyecto.**

La migración en `supabase/migrations/` fue creada con la CLI y ejecutada en
PostgreSQL local mediante PGlite. Se probó el rechazo de lectura por un rol sin
privilegios. La compatibilidad con la plataforma Supabase completa, sus asesores,
Auth y Realtime sigue pendiente de acceso y despliegue. El esquema actual guarda
entidades y sus payloads JSONB; todavía no representa todo el modelo relacional
de temporadas, reglas y eventos definido en la arquitectura.

## Próximo incremento

Una vez disponible el acceso: revisar el esquema remoto, preparar el adaptador
PostgreSQL de servidor y verificar migración y permisos en Supabase. Después:
scheduler con cuotas/bloqueos/reintentos, ciclo de partido y reconciliación;
reglas por temporada antes de construir la tabla LIVE.
