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

En el despliegue inicial, dos intentos controlados fallaron antes de publicar
un lote y el ledger alcanzó su límite diario; el snapshot real anterior quedó
intacto. El worker v2 añade cabeceras explícitas y diagnóstico por etapa. El
siguiente ciclo programado después del reinicio UTC validará la importación
remota completa sin saltarse la cuota. Los mismos cinco endpoints y la
normalización completa fueron verificados localmente (1 competición, 28
equipos observados, 2 partidos y tabla disponible).

LIVE continúa usando el scheduler API-Football existente. Los favoritos y
partidos abiertos alimentan `coverage_interests` para que futuros planners
escojan profundidad y frecuencia sin acoplarse a un proveedor concreto.

## UI

La tarjeta inicial no bloquea la aplicación. Permite continuar con la región
detectada, cambiar país, seguir competición/equipos y abrir la búsqueda.
Perfil conserva el mismo selector. Si se elige una región sin cobertura, la
app lo indica y nunca sustituye cloud con el fixture demo.
