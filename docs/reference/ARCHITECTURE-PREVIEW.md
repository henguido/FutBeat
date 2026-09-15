# Referencia recuperada

Vista de la conversación «Crear arquitectura FutBeat», 15 septiembre 2026. El adjunto original completo está disponible en el proyecto; esta vista puede estar truncada al final.

Sí. Con todo lo que definimos, ya podemos cerrar una **Arquitectura FutBeat v1** suficientemente sólida para empezar a desarrollar. La plantearía desde el principio para tres objetivos: **máxima automatización**, **mínimo costo inicial** y **uso intensivo de escudos/fotos siempre que tengamos una fuente utilizable y derechos suficientes**.

# Arquitectura FutBeat v1

```text
                            ┌─────────────────────┐
                            │     FUTBEAT APP     │
                            │    Flutter/Dart     │
                            │ Android → iOS       │
                            └──────────┬──────────┘
                                       │
                               HTTPS / Realtime
                                       │
                            ┌──────────▼──────────┐
                            │    FUTBEAT API      │
                            │ Backend / BFF       │
                            └──────────┬──────────┘
                                       │
                     ┌─────────────────┼─────────────────┐
                     │                 │                 │
                     ▼                 ▼                 ▼
               FUTBEAT CORE      PERSONALIZATION     SEARCH
                     │              ENGINE           ENGINE
                     │
       ┌─────────────┼────────────────────────────────────┐
       │             │              │                     │
       ▼             ▼              ▼                     ▼
 Match Engine    Data Engine   Content Engine       Media Engine
       │             │              │                     │
       │             │              │             Fotos / Escudos
       │             │              │             Licencias/Fallback
       ▼             ▼              ▼
 Live Scores     Providers       News
 Events          Normalizer      Transfers
 Lineups         Entity Match    YouTube
 Statistics      Verification    Videos
 Standings
       │
       └─────────────────┬──────────────────────┐
                         ▼                      ▼
                 Automation Engine        Quality Engine
                         │                      │
                  Jobs / Scheduler       Reconciliation
                  Retries                Confidence
                  Monitoring             Duplicates
                  Recovery               Conflicts
                         │
                         ▼
                    SUPABASE
              PostgreSQL / Realtime
                Auth / Storage
```

---

# 1. Aplicación móvil

Seguimos con una **app móvil nativa compilada**, no un sitio web dentro de una aplicación.

### Tecnología

```text
Flutter
Dart
Riverpod
GoRouter
Dio
Drift/SQLite
Firebase Cloud Messaging
Firebase Crashlytics
```

Una sola base de código:

```text
FutBeat
 ├── Android
 └── iOS
```

Android sería nuestro lanzamiento inicial.

---

# 2. Navegación principal

Mantendría cinco secciones principales:

```text
Partidos
Noticias
Explorar
Favoritos / Siguiendo
Perfil
```

Y acceso global a:

```text
🔍 Buscar
```

Desde ahí podremos entrar a cualquiera de las entidades principales.

---

# 3. El Entity Graph de FutBeat

Éste será probablemente uno de los conceptos más importantes de toda la arquitectura.

FutBeat no debe pensar en páginas independientes.

Debe pensar en **entidades relacionadas**.

```text
                     Competition
                    /           \
                   /             \
                Team ───────── Match
                 │ \            / │
                 │  \          /  │
                 │   Player       │
                 │      │         │
                 │      │         │
                 ├──── News ──────┤
                 │      │         │
                 ├── Transfer ────┤
                 │                │
                 └──── Media ─────┘
```

Esto permite que un contenido descubierto una sola vez aparezca automáticamente donde corresponda.

Ejemplo:

```text
Video:
Saprissa 2-1 Herediano | Resumen
```

FutBeat lo relaciona con:

```text
Match
├── Saprissa
├── Herediano
├── Liga Promerica
└── jugadores relacionados
```

El mismo video aparece automáticamente en todos esos lugares.

---

# 4. Entidades principales

Tendremos inicialmente:

```text
countries

competitions
seasons

teams
team_seasons

players
player_team_history

coaches
coach_team_history

matches
match_events
match_statistics
match_lineups
match_players

standings
standings_rows

transfers

news_articles

media_assets
media_items

venues

users
```

No pondremos todo en una tabla gigantesca.

---

# 5. Página de equipo

Ruta conceptual:

```text
/team/{teamId}
```

Ejemplo:

```text
Deportivo Saprissa     ⭐ Seguir

[ESCUDO]

Costa Rica
Liga Promerica

Resumen
Partidos
Tabla
Plantilla
Transferencias
Noticias
Estadísticas
Videos
Información
```

### Resumen

Se construye automáticamente con:

```text
Próximo partido
Último partido
Forma
Posición
Tabla
Noticias recientes
Transferencias
Videos
Jugadores destacados
```

No existe una página estática que tengamos que mantener.

---

# 6. Página del jugador

Ruta:

```text
/player/{playerId}
```

Tendrá:

```text
              [FOTO]

          Nombre jugador
             ⭐ Seguir

        [escudo] Equipo
        Posición · País

Resumen
Partidos
Estadísticas
Noticias
Transferencias
Carrera
Videos
```

Y datos como:

```text
Partidos
Titularidades
Minutos
Goles
Asistencias
Tarjetas
Porterías a cero
```

según la posición y la información disponible.

También historial:

```text
2026    Saprissa
2025    Herediano
2023    Equipo X
```

Sin destruir información histórica cuando cambie de club.

---

# 7. Página de competición

También será entidad principal:

```text
/competition/{competitionId}
```

Por ejemplo:

```text
[LOGO]
Liga Promerica         ⭐ Seguir

Resumen
Partidos
Tabla LIVE
Equipos
Noticias
Estadísticas
Goleadores
Asistencias
Transferencias
Videos
Temporadas
```

Esto también aplica a:

```text
Champions League
Premier League
LaLiga
Copa del Mundo
Concacaf
etc.
```

---

# 8. Match Center

Será probablemente la pantalla más importante durante los partidos.

```text
Saprissa             Alajuelense
 [logo]       2 - 1      [logo]

              67' LIVE
```

Pestañas:

```text
Resumen
Eventos
Alineaciones
Estadísticas
Tabla LIVE
H2H
Noticias
Videos
Información
```

Eventos:

```text
⚽ 17' Gol Saprissa
🟨 31' Tarjeta
🔄 58' Sustitución
⚽ 67' Gol Alajuelense
```

---

# 9. Match Lifecycle Engine

Cada partido tendrá una máquina de estados.

```text
DISCOVERED
     ↓
SCHEDULED
     ↓
PRE_MATCH
     ↓
LIVE
     ↓
HALFTIME
     ↓
LIVE
     ↓
FINISHED_PENDING_VERIFICATION
     ↓
VERIFIED
```

Además:

```text
POSTPONED
SUSPENDED
ABANDONED
CANCELLED
EXTRA_TIME
PENALTIES
```

Esto dispara automáticamente el resto del sistema.

---

# 10. Tabla LIVE

No dependeremos de que otra API nos mande una tabla actualizada después de cada gol.

Tendremos:

```text
LiveStandingsEngine
```

Ejemplo:

```text
Minuto 0

1 Alajuelense       28
2 Saprissa          26


Saprissa 0-0 Herediano

tabla LIVE:

1 Alajuelense       28
2 Saprissa          27


Saprissa 1-0 Herediano

tabla LIVE:

1 Saprissa          29
2 Alajuelense       28
```

Todos los partidos simultáneos de esa competición participan en el cálculo.

---

# 11. Competition Rules Engine

Fundamental para que esa tabla sea correcta.

Cada temporada podrá definir:

```text
puntos_victoria
puntos_empate
puntos_derrota

desempates

fases
grupos
playoffs
semifinales
finales

ida_y_vuelta
gol_visitante si corresponde

descensos
clasificaciones

deducciones_puntos
```

Así FutBeat puede soportar desde Costa Rica hasta Champions, Mundial, MLS, etc.

---

# 12. Verificación al terminar

Cuando termina un partido no lo consideramos inmediatamente definitivo.

```text
FINISHED
    ↓
PostMatchVerification
```

Comparamos:

```text
Resultado FutBeat
Fuente primaria
Fuente secundaria
Fuente oficial si existe
```

Si:

```text
2-1
2-1
2-1
```

entonces:

```text
VERIFIED ✓
```

Después hacemos lo mismo con:

```text
tabla
eventos
estadísticas
goleadores
tarjetas
```

---

# 13. Data Provider Layer

La app nunca se conecta directamente a una API deportiva.

```text
API externa
      ↓
Adapter
      ↓
Normalizer
      ↓
Entity Resolver
      ↓
FutBeat
```

Interfaces:

```text
getCompetitions()
getSeasons()
getTeams()
getPlayers()

getFixtures()
getLiveMatches()
getMatchEvents()
getLineups()
getStatistics()

getStandings()
getTransfers()
```

Podremos tener:

```text
CostaRicaProvider
ProviderA
ProviderB
ProviderC
```

sin cambiar Flutter.

---

# 14. Entity Resolution Engine

Resolverá automáticamente:

```text
Liga Deportiva Alajuelense
LD Alajuelense
Alajuelense
LDA
```

como:

```text
team_id = futbeat_team_123
```

Y lo mismo con:

```text
jugadores
ligas
entrenadores
estadios
```

Guardaremos:

```text
provider_entities
```

con la equivalencia de cada proveedor.

---

# 15. Automation Engine

Éste será el corazón operacional.

Eventos:

```text
MATCH_DISCOVERED
MATCH_STARTING_SOON
LINEUP_AVAILABLE

MATCH_STARTED
GOAL
HALFTIME
MATCH_FINISHED

STANDINGS_CHANGED

NEWS_FOUND
TRANSFER_FOUND

VIDEO_FOUND
HIGHLIGHT_FOUND

SOURCE_FAILED
DATA_CONFLICT
```

Cada evento puede disparar múltiples jobs.

Ejemplo:

```text
MATCH_FINISHED
       │
       ├── VerifyResult
       ├── FinalizeStandings
       ├── UpdateTeamForm
       ├── UpdatePlayerStats
       ├── UpdateH2H
       ├── FindNews
       ├── FindHighlights
       └── NotifyFollowers
```

Nada manual.

---

# 16. Noticias automáticas

Tendremos:

```text
NewsDiscoveryEngine
```

Fuentes:

```text
RSS
APIs
Feeds autorizados
Fuentes oficiales
Otros conectores legales
```

Después:

```text
noticia
   ↓
Entity Matcher
   ↓
Team
Player
Competition
Match
Transfer
```

Ejemplo:

```text
"Saprissa anuncia la llegada de Juan Pérez"

team:
Saprissa 99%

player:
Juan Pérez 98%

category:
TRANSFER 99%
```

Aparece automáticamente en ambos perfiles.

---

# 17. Deduplicación de noticias

Cinco medios pueden publicar el mismo fichaje.

FutBeat crea:

```text
StoryCluster
```

Ejemplo:

```text
TRANSFERENCIA JUAN PÉREZ → SAPRISSA

Fuente A
Fuente B
Fuente C
Fuente oficial
```

En lugar de llenar el feed con cuatro noticias casi iguales.

---

# 18. Transfer Engine

Tendrá estados:

```text
RUMOR
REPORTED
ADVANCED
CONFIRMED
CANCELLED
```

Ejemplo:

```text
Jugador X → Saprissa

Rumor
    ↓
Reportado
    ↓
Confirmado
```

Cuando detectemos anuncio oficial:

```text
official_confirmation = true
```

Y se actualiza automáticamente la ficha.

---

# 19. YouTube / Highlights Engine

Después del partido:

```text
FindHighlightsJob
```

Primero:

```text
Canales oficiales
Canales de liga
Canales de equipos
Broadcasters permitidos
```

Luego búsqueda general como fallback.

Clasificación:

```text
HIGHLIGHTS
GOAL
FULL_MATCH
PRESS_CONFERENCE
INTERVIEW
ANALYSIS
```

Matcher:

```text
equipos
fecha
competición
partido
canal
título
publicación
```

Confidence:

```text
0.97
```

si supera el umbral:

```text
AUTO_PUBLISH
```

Y aparece en:

```text
Partido
Equipo local
Equipo visitante
Competición
Feed del usuario
```

---

# 20. Media Engine: fotos y escudos

Aquí aplicamos tu decisión:

> **usar imágenes siempre que podamos hacerlo razonablemente.**

No quiero que FutBeat se vea lleno de placeholders si podemos obtener imágenes adecuadas.

Orden de preferencia:

```text
1. Asset oficial/licenciado
2. Proveedor con derechos compatibles
3. Fuente Creative Commons compatible
4. Fuente oficialmente autorizada
5. Placeholder FutBeat
```

El sistema seleccionará automáticamente la mejor disponible.

---

# 21. Media Rights Engine

Cada imagen tendrá metadatos.

```text
media_assets

id
entity_type
entity_id

type
source
url

license_type
license_url
rights_holder

commercial_use_allowed
redistribution_allowed
attribution_required

valid_from
valid_until

verification_status

width
height
quality_score
```

Tipos:

```text
TEAM_LOGO
PLAYER_PHOTO
COMPETITION_LOGO
COUNTRY_FLAG
COACH_PHOTO
STADIUM_PHOTO
ARTICLE_IMAGE
```

---

# 22. Selección automática de imagen

Además agregaría:

```text
MediaSelectionEngine
```

Podemos tener cinco fotografías disponibles de un jugador.

FutBeat calcula:

```text
licencia válida          +50
foto reciente            +20
buena resolución         +10
rostro visible            +10
fuente oficial            +10
```

Y escoge automáticamente la mejor.

Por ejemplo:

```text
foto A → 95
foto B → 72
foto C → 66

PRIMARY_PHOTO = A
```

Sin administrador.

---

# 23. Actualización automática de fotos

Si aparece una imagen mejor:

```text
foto actual:
temporada 2024
quality 78

nueva:
temporada 2026
quality 96
```

FutBeat puede automáticamente cambiar:

```text
PRIMARY
```

sin borrar la anterior.

---

# 24. Fallbacks visuales

Si no tenemos fotografía autorizada:

Jugador:

```text
┌───────────┐
│           │
│    👤     │
│           │
└───────────┘
```

Equipo:

```text
┌───────────┐
│    SAP    │
└───────────┘
```

Pero deberían ser la excepción, no nuestro diseño principal.

---

# 25. Personalization Engine

Un usuario podrá seguir:

```text
Teams
Players
Competitions
Matches
National teams
```

Ejemplo:

```text
Usuario sigue:

Saprissa
Real Madrid
Costa Rica
Keylor Navas
Champions League
```

FutBeat construye automáticamente su universo de contenido.

---

# 26. Feed personalizado

```text
PARA TI
```

Puede mezclar:

```text
Próximos partidos
Resultados
Noticias
Transferencias
Highlights
Videos
Cambios de tabla
Alineaciones
Noticias de jugadores
```

según lo que sigue.

---

# 27. Notification Decision Engine

No todo genera push.

Prioridades:

```text
CRITICAL
Inicio partido
Gol
Resultado

HIGH
Alineación
Transferencia confirmada
Partido reprogramado

MEDIUM
Noticia importante

LOW
Feed solamente
```

El usuario controla:

```text
☑ Goles
☑ Inicio
☑ Final
☑ Alineaciones
☑ Noticias
☑ Transferencias
☑ Videos/resúmenes
```

---

# 28. Search Engine

Búsqueda universal:

```text
🔍 keylor
```

Resultados:

```text
JUGADORES
Keylor Navas

EQUIPOS
...

NOTICIAS
...
```

Indexará:

```text
teams
players
competitions
news
```

Y tendrá aliases:

```text
liga
lda
saprissa
sapri
man utd
manchester united
```

---

# 29. Quality Engine

Cada dato tendrá:

```text
source
confidence
received_at
verified_at
verification_status
```

Estados:

```text
UNVERIFIED
PROVISIONAL
VERIFIED
CONFLICT
```

Esto es particularmente importante para LIVE.

---

# 30. Source Health Engine

Cada proveedor tendrá métricas:

```text
availability
latency
accuracy
last_success
error_rate
quota_remaining
```

Ejemplo:

```text
Provider A
health = DEGRADED
```

Entonces:

```text
A pierde prioridad
B toma el control
```

automáticamente.

---

# 31. Sistema de jobs

Estados:

```text
PENDING
RUNNING
SUCCESS
RETRY
FAILED
NEEDS_REVIEW
```

Con:

```text
retry
backoff
deduplication
idempotency
locking
audit
```

Un mismo gol procesado tres veces nunca debe generar tres goles.

---

# 32. Freshness Engine

Decide cuándo actualizar cada dato.

Ejemplo:

```text
Partido >7 días       muy poco
Partido mañana        periódico
Partido <1 hora       frecuente
Partido LIVE          máxima frecuencia posible

Tabla LIVE            después de cada cambio
Noticias              periódicamente
Transferencias        periódicamente

Plantillas            diario
Club information      ocasional
```

Evita gastar requests innecesariamente.

---

# 33. Arquitectura de base de datos

La estructura inicial quedaría aproximadamente:

```text
CORE
countries
venues

competitions
competition_seasons
competition_rules

teams
team_aliases
team_seasons

players
player_aliases
player_team_history

coaches
coach_team_history
```

```text
MATCH
matches
match_status_history
match_events
match_lineups
match_lineup_players
match_statistics
match_player_statistics
```

```text
STANDINGS
standings
standings_rows
standings_snapshots
```

Los `standings_snapshots` permitirán incluso ver:

```text
tabla minuto 0
tabla minuto 30
tabla minuto 68
tabla final
```

---

# 34. Contenido

```text
news_sources
news_articles
news_entities
story_clusters

transfers
transfer_sources

media_items
media_entities
youtube_channels

media_assets
media_rights
```

---

# 35. Proveedores y calidad

```text
providers
provider_entities
provider_requests
provider_health

data_observations
data_conflicts
verification_runs
```

`data_observations` me parece especialmente útil.

En lugar de:

```text
score = 2-1
```

podemos saber internamente:

```text
Provider A → 2-1
Provider B → 2-1
Provider C → 1-1
Official   → 2-1
```

Y Quality Engine determina:

```text
canonical = 2-1
confidence = 0.99
```

---

# 36. Automatización

```text
automation_jobs
automation_runs
automation_failures
automation_locks
```

Y el administrador casi únicamente verá:

```text
NEEDS_REVIEW
```

---

# 37. Usuario

```text
users

user_followed_teams
user_followed_players
user_followed_competitions
user_followed_matches

notification_preferences

user_hidden_scores
```

Ese último sirve para modo spoiler.

---

# 38. Cache local

El móvil mantiene:

```text
partidos recientes
favoritos
tablas
equipos
jugadores vistos
noticias recientes
```

Así FutBeat sigue siendo útil con una conexión deficiente.

---

# 39. Backend inicial

Para mantener costos prácticamente en cero:

```text
Supabase

PostgreSQL
Auth
Realtime
Storage
Edge Functions donde tenga sentido
```

Más:

```text
Cloudflare Workers
```

para:

```text
scheduled jobs
providers
news
YouTube
sync
```

No empezaría con Kubernetes, Kafka ni infraestructura exagerada.

---

# 40. Monorepo

Ahora cambiaría ligeramente la estructura anterior:

```text
futbeat/
│
├── apps/
│   ├── mobile/
│   │
│   └── admin/
│
├── packages/
│   ├── domain/
│   ├── contracts/
│   └── shared/
│
├── backend/
│   │
│   ├── api/
│   │
│   ├── automation/
│   │
│   ├── providers/
│   │   ├── core/
│   │   ├── costa_rica/
│   │   └── international/
│   │
│   ├── engines/
│   │   ├── match/
│   │   ├── standings/
│   │   ├── competition_rules/
│   │   ├── entities/
│   │   ├── news/
│   │   ├── transfers/
│   │   ├── highlights/
│   │   ├── personalization/
│   │   ├── notifications/
│   │   ├── quality/
│   │   ├── media/
│   │   └── media_rights/
│   │
│   └── workers/
│
├── supabase/
│   ├── migrations/
│   ├── seed/
│   └── functions/
│
├── docs/
│   ├── ARCHITECTURE.md
│   ├── DATABASE.md
│   ├── AUTOMATION.md
│   ├── PROVIDERS.md
│   ├── MEDIA-RIGHTS.md
│   ├── COMPETITION-RULES.md
│   └── ROADMAP.md
│
└── README.md
```

---

# 41. Panel administrativo

No será un CMS tradicional.

Será un **Operations Center**.

```text
FUTBEAT OPERATIONS

LIVE                           47
Partidos hoy                  312
Jobs                           98%

Providers
12 / 12 saludables

Media
97% equipos con imagen
72% jugadores con foto

Verification
301 verified
4 pending
1 conflict

Requires review
2
```

Ahí está nuestra intervención.

No:

> cargar noticia.

Sino:

> revisar anomalía.

---

# 42. Automatización visual

Incluso agregaría automáticamente:

```text
MissingMediaJob
```

Cuando FutBeat descubre:

```text
Nuevo jugador
```

dispara:

```text
buscar foto
      ↓
validar fuente
      ↓
validar licencia
      ↓
quality score
      ↓
asociar
```

Si no encuentra:

```text
PLACEHOLDER
```

Y volverá a intentar periódicamente.

Lo mismo para:

```text
equipo
competición
entrenador
estadio
```

---

# 43. Flujo completo que debemos conseguir

Nuestro primer verdadero milestone debería ser éste:

```text
      SE DESCUBRE PARTIDO
              ↓
       equipos identificados
              ↓
     escudos/fotos obtenidos
              ↓
        partido programado
              ↓
      alineación encontrada
              ↓
          empieza LIVE
              ↓
     eventos + estadísticas
              ↓
      tabla LIVE cambia
              ↓
           termina
              ↓
      resultado verificado
          
