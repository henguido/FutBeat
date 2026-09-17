# Country Bootstrap + Favorites-First

## Señales y privacidad

FutBeat usa únicamente la región del locale del sistema. No solicita GPS,
coordenadas ni permisos de ubicación. La región detectada es una sugerencia y
nunca crea un favorito.

Las señales se mantienen separadas:

- `detectedCountry`: región inferida localmente.
- `selectedCountry`: elección manual, que reemplaza la sugerencia.
- `Follows`: equipos, jugadores, competiciones y partidos explícitos.
- `TemporaryInterests`: entidad abierta, con caducidad de 30 minutos.

Sin cuenta, todas las preferencias permanecen en Drift. Con sesión iniciada se
sincronizan por RPC cuya identidad procede de `auth.uid()`.

## Prioridad y profundidad

| Señal | Cobertura | Prioridad |
|---|---|---:|
| Favorito explícito | Profunda | 1 000 000+ |
| País seleccionado | Base | 100 000+ |
| País detectado | Base | 10 000+ |
| Interés temporal | Temporal | 1 000+ |
| Global | Base/fallback | 1 |

Los rangos evitan que el volumen de usuarios de una categoría cambie el orden
semántico. La excepción es una pantalla de partido abierta: alineaciones,
eventos y estadísticas reciben prioridad temporal cercana a profunda durante
su TTL, sin crear un favorito.

Supabase agrega por `entity_type + entity_id`. Cinco mil seguidores del mismo
equipo producen una sola fila de trabajo con contador 5000. El planner es
independiente del proveedor.

## Costa Rica

`fb_comp_cr` representa la Primera División de Costa Rica. El bootstrap
compartido consulta TheSportsDB dos veces al día, bajo el ledger existente, y
normaliza:

- competición y equipos;
- próximos partidos y resultados recientes;
- tabla cuando la fuente la publica;
- procedencia, fecha de recepción e IDs canónicos.

La tabla puede estar ausente porque la API gratuita solo la ofrece para ligas
destacadas. La app muestra “no disponible”; no rellena datos ficticios.
El snapshot válido anterior se conserva si cualquier lectura o validación
falla.

El `404` observado en `store` no provenía de la resolución de PostgREST. La
función existía, estaba expuesta en `public` y `service_role` tenía `EXECUTE`.
PostgreSQL producía `42883` al comparar `imports.job_id` (`text`) con el
parámetro `p_job_id` (`uuid`); la Data API traduce ese código a HTTP 404. La
migración `fix_country_snapshot_job_id_type` convierte el UUID explícitamente
a texto tanto al deduplicar como al guardar. Una llamada transaccional como
`service_role` confirmó que el wrapper devuelve `{"duplicate":true}` y que
`anon` y `authenticated` siguen sin permiso.

Después de la corrección se autorizó una sola sincronización real. Los intentos
fallidos del mismo día ya habían ocupado el límite, por lo que se amplió una
vez de 2 a 3 sin borrar el ledger y luego se restauró a 2. Esa ejecución llegó
a TheSportsDB pero terminó en `fetch` tras unos 41 segundos; no alcanzó
`normalize` ni `store` y no creó un import. El último snapshot publicado sigue
siendo real (`demo=false`), recibido el 2026-09-16 02:36:22 UTC: 1 competición,
4 equipos, 2 partidos (un resultado pasado y un próximo partido) y 0 tablas.
TheSportsDB puede omitir la tabla y cualquiera de sus cinco endpoints gratuitos
puede agotar el timeout. No se hizo un segundo intento automático.

### Fetch resiliente y cobertura por capacidad

`league` se consulta primero para obtener la temporada. Luego `next`, `past`,
`teams` y `table` se consultan en paralelo, una vez por endpoint y sin retries.
Cada diagnóstico conserva solamente nombre lógico, ruta pública, duración,
estado HTTP, error seguro y cantidad de elementos; no incluye cabeceras ni
credenciales.

La condición mínima de publicación es una liga válida de Costa Rica y al menos
un equipo de fútbol canónico válido. `teams` y `league` son críticos. `next` y
`past` se degradan de forma independiente y `table` es opcional. Un timeout o
error HTTP de esas capacidades produce `unavailable` o
`temporarily_unavailable`; una respuesta exitosa malformada rechaza el lote.
Un `null` válido conserva `available` con cero elementos. El snapshot publica
este estado para equipos, próximos partidos, resultados anteriores y tabla,
incluyendo `stale=false` en una importación recién recibida. Nunca se rellena
una capacidad ausente con datos demo.

LIVE continúa usando el scheduler API-Football existente. Los favoritos y
partidos abiertos alimentan `coverage_interests` para que futuros planners
escojan profundidad y frecuencia sin acoplarse a un proveedor concreto.

## UI

La tarjeta inicial no bloquea la aplicación. Permite continuar con la región
detectada, cambiar país, seguir competición/equipos y abrir la búsqueda.
Perfil conserva el mismo selector. Si se elige una región sin cobertura, la
app lo indica y nunca sustituye cloud con el fixture demo.
