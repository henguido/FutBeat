# Historias originales — extracto recuperado

Fuente: «Crear historias de usuario», 15 septiembre 2026. Vista limitada a 20.000 caracteres; no representa todo el backlog. No inventar IDs posteriores.

Tomando como base la arquitectura FutBeat v1 que definimos —app Flutter, Entity Graph, Match Center, páginas de equipo/jugador/competición, automatización, tabla LIVE, noticias, transferencias, videos, Media Engine, personalización, Quality Engine y Operations Center—, este sería el **backlog inicial de historias de usuario de FutBeat**. fileciteturn0file0

He separado las historias en épicas y además marco la prioridad:

- **P0** = imprescindible para MVP.
- **P1** = muy importante para primera versión pública.
- **P2** = mejora posterior.
- **AUTO** = historia principalmente automatizada/backend.

---

# ÉPICA 1 — Inicio, descubrimiento y navegación

### FB-US-001 — Ver los partidos del día — P0

**Como** aficionado al fútbol  
**quiero** ver los partidos programados para hoy  
**para** saber qué encuentros se disputan y a qué hora.

**Criterios de aceptación**
- Mostrar partidos agrupados por competición.
- Mostrar hora local del usuario.
- Mostrar escudos cuando estén disponibles.
- Mostrar estado: próximo, en vivo, finalizado, suspendido, etc.
- Permitir abrir el Match Center.
- Los datos deben actualizarse sin intervención manual.

---

### FB-US-002 — Navegar entre días — P0

**Como** usuario  
**quiero** consultar partidos de días anteriores y posteriores  
**para** revisar resultados pasados y próximos encuentros.

**Criterios**
- Poder avanzar y retroceder por fecha.
- Mostrar rápidamente “Ayer”, “Hoy” y “Mañana”.
- Mantener la misma estructura por competición.

---

### FB-US-003 — Explorar competiciones — P1

**Como** usuario  
**quiero** explorar competiciones por país  
**para** encontrar ligas que no sigo todavía.

**Criterios**
- Mostrar país.
- Nombre de competición.
- Logo si existe.
- Permitir acceder a su página.
- Permitir seguirla.

---

### FB-US-004 — Abrir cualquier entidad desde el contenido — P0

**Como** usuario  
**quiero** poder tocar un equipo, jugador o competición  
**para** acceder inmediatamente a su perfil.

**Criterios**
- Equipos enlazan a `/team/{id}`.
- Jugadores enlazan a `/player/{id}`.
- Competiciones enlazan a `/competition/{id}`.
- Los IDs internos deben ser independientes del proveedor externo.

---

# ÉPICA 2 — Match Center

### FB-US-005 — Consultar el Match Center — P0

**Como** aficionado  
**quiero** abrir la página de un partido  
**para** conocer toda la información disponible del encuentro.

**Criterios**
- Mostrar equipos.
- Escudos.
- Resultado.
- Estado.
- Minuto cuando esté LIVE.
- Fecha y hora.
- Competición.
- Acceso a información adicional mediante pestañas.

---

### FB-US-006 — Ver eventos del partido — P0

**Como** aficionado  
**quiero** ver cronológicamente los eventos del partido  
**para** entender cómo se está desarrollando.

**Criterios**
- Goles.
- Tarjetas.
- Sustituciones.
- Penalizaciones cuando estén disponibles.
- Minuto del evento.
- Jugador relacionado cuando exista.
- Actualización automática durante LIVE.

---

### FB-US-007 — Ver alineaciones — P1

**Como** usuario  
**quiero** consultar las alineaciones  
**para** saber qué jugadores participan en el encuentro.

**Criterios**
- Titulares.
- Suplentes.
- Formación cuando esté disponible.
- Foto del jugador cuando exista.
- Posición.
- Permitir abrir perfil del jugador.

---

### FB-US-008 — Ver estadísticas del partido — P1

**Como** usuario  
**quiero** comparar las estadísticas de ambos equipos  
**para** comprender el desarrollo del encuentro.

**Criterios**
- Mostrar únicamente estadísticas disponibles.
- Identificar claramente cada equipo.
- Actualizar estadísticas mientras el partido esté LIVE.

---

### FB-US-009 — Ver tabla LIVE desde el partido — P1

**Como** aficionado  
**quiero** saber cómo afecta el resultado actual a la tabla  
**para** conocer la posición provisional de mi equipo.

**Criterios**
- Utilizar todos los partidos simultáneos relevantes.
- Actualizar después de cambios en resultados.
- Diferenciar tabla provisional de tabla oficial/final.

---

### FB-US-010 — Consultar enfrentamientos anteriores — P2

**Como** aficionado  
**quiero** consultar los enfrentamientos anteriores entre los equipos  
**para** conocer su historial reciente.

---

### FB-US-011 — Ver contenido posterior al partido — P1

**Como** usuario  
**quiero** encontrar noticias y videos relacionados con un partido terminado  
**para** continuar siguiendo lo ocurrido después del encuentro.

**Criterios**
- Noticias relacionadas.
- Highlights.
- Entrevistas.
- Conferencias cuando existan.

---

# ÉPICA 3 — Ciclo de vida del partido

### FB-US-012 — Identificar automáticamente el estado del partido — P0 · AUTO

**Como** usuario  
**quiero** que FutBeat refleje correctamente el estado real del partido  
**para** saber si está próximo, en juego o finalizado.

**Criterios**
- Soportar SCHEDULED.
- PRE_MATCH.
- LIVE.
- HALFTIME.
- FINISHED.
- POSTPONED.
- SUSPENDED.
- ABANDONED.
- CANCELLED.
- EXTRA_TIME.
- PENALTIES.

---

### FB-US-013 — Iniciar actualización intensiva al comenzar un partido — P0 · AUTO

**Como** usuario  
**quiero** que FutBeat aumente automáticamente la frecuencia de actualización cuando comience un partido  
**para** recibir información lo más cercana posible al tiempo real.

---

### FB-US-014 — Verificar el resultado al finalizar — P0 · AUTO

**Como** usuario  
**quiero** que el resultado final sea verificado  
**para** reducir errores de fuentes externas.

**Criterios**
- Estado inicial `FINISHED_PENDING_VERIFICATION`.
- Comparar fuentes disponibles.
- Marcar `VERIFIED` cuando exista suficiente confianza.
- Registrar conflicto cuando las fuentes discrepen.

---

# ÉPICA 4 — Tabla de posiciones

### FB-US-015 — Consultar tabla de posiciones — P0

**Como** aficionado  
**quiero** ver la tabla de una competición  
**para** conocer la posición de cada equipo.

**Criterios**
- Posición.
- Partidos.
- Ganados.
- Empatados.
- Perdidos.
- Goles cuando estén disponibles.
- Diferencia de gol.
- Puntos.

---

### FB-US-016 — Recalcular automáticamente la tabla LIVE — P1 · AUTO

**Como** aficionado  
**quiero** que la tabla cambie durante los partidos  
**para** visualizar la clasificación provisional.

---

### FB-US-017 — Aplicar las reglas específicas de cada competición — P0 · AUTO

**Como** usuario  
**quiero** que FutBeat respete las reglas de cada torneo  
**para** que la clasificación mostrada sea correcta.

**Criterios**
- Puntos victoria/empate/derrota.
- Desempates.
- Grupos.
- Fases.
- Deducciones.
- Clasificación y descenso.
- Reglas dependientes de temporada.

---

### FB-US-018 — Reconciliar la tabla tras los partidos — P0 · AUTO

**Como** usuario  
**quiero** que FutBeat compruebe la tabla después de los encuentros  
**para** detectar y corregir inconsistencias.

---

# ÉPICA 5 — Página de equipo

### FB-US-019 — Consultar perfil de equipo — P0

**Como** aficionado  
**quiero** abrir la página de cualquier equipo  
**para** encontrar toda su información en un mismo lugar.

**Criterios**
- Nombre.
- Escudo.
- País.
- Competición.
- Botón Seguir.
- Información principal.

---

### FB-US-020 — Ver resumen del equipo — P0

**Como** aficionado  
**quiero** obtener rápidamente un resumen de mi equipo  
**para** conocer su situación actual.

**Criterios**
- Próximo partido.
- Último resultado.
- Posición.
- Forma reciente.
- Noticias.
- Videos cuando existan.

---

### FB-US-021 — Consultar partidos de un equipo — P0

**Como** usuario  
**quiero** ver los partidos pasados y futuros de un equipo  
**para** consultar su calendario.

---

### FB-US-022 — Consultar plantilla del equipo — P1

**Como** usuario  
**quiero** consultar la plantilla actual  
**para** conocer sus jugadores.

**Criterios**
- Jugador.
- Foto.
- Posición.
- Nacionalidad cuando exista.
- Acceso al perfil.

---

### FB-US-023 — Consultar noticias del equipo — P1

**Como** seguidor  
**quiero** encontrar noticias relacionadas con el equipo  
**para** mantenerme informado.

---

### FB-US-024 — Consultar transferencias del equipo — P1

**Como** seguidor  
**quiero** consultar llegadas, salidas y rumores  
**para** seguir el mercado de fichajes.

---

### FB-US-025 — Consultar videos del equipo — P1

**Como** seguidor  
**quiero** encontrar videos relacionados con el equipo  
**para** ver resúmenes, goles, entrevistas y contenido oficial.

---

# ÉPICA 6 — Página de jugador

### FB-US-026 — Consultar perfil del jugador — P1

**Como** aficionado  
**quiero** consultar la página de un jugador  
**para** conocer información sobre él.

**Criterios**
- Foto.
- Nombre.
- Equipo.
- Posición.
- Nacionalidad cuando exista.
- Botón Seguir.

---

### FB-US-027 — Consultar estadísticas del jugador — P1

**Como** usuario  
**quiero** consultar las estadísticas de un jugador  
**para** analizar su rendimiento.

**Criterios según disponibilidad**
- Partidos.
- Titularidades.
- Minutos.
- Goles.
- Asistencias.
- Tarjetas.
- Estadísticas específicas según posición.

---

### FB-US-028 — Consultar carrera del jugador — P1

**Como** usuario  
**quiero** consultar los equipos anteriores de un jugador  
**para** conocer su trayectoria profesional.

**Criterios**
- No eliminar historia al cambiar de club.
- Mostrar periodos asociados a cada equipo.

---

### FB-US-029 — Consultar noticias del jugador — P1

**Como** seguidor de un jugador  
**quiero** recibir contenido relacionado con él  
**para** seguir su actualidad incluso fuera de su club.

---

### FB-US-030 — Consultar historial de transferencias — P2

**Como** usuario  
**quiero** consultar los movimientos anteriores de un jugador  
**para** comprender su trayectoria entre clubes.

---

# ÉPICA 7 — Página de competición

### FB-US-031 — Consultar página de competición — P0

**Como** aficionado  
**quiero** abrir la página de una liga o torneo  
**para** consultar toda su información.

**Criterios**
- Logo.
- Nombre.
- País/región.
- Temporada actual.
- Seguir competición.

---

### FB-US-032 — Consultar partidos de competición — P0

**Como** usuario  
**quiero** ver todos los encuentros de una competición  
**para** seguir la jornada completa.

---

### FB-US-033 — Consultar equipos participantes — P1

**Como** usuario  
**quiero** ver los equipos participantes  
**para** acceder rápidamente a sus perfiles.

---

### FB-US-034 — Consultar goleadores y líderes estadísticos — P2

**Como** aficionado  
**quiero** conocer los jugadores destacados del torneo  
**para** seguir la competencia individual.

---

### FB-US-035 — Consultar temporadas anteriores — P2

**Como** usuario  
**quiero** seleccionar temporadas anteriores  
**para** consultar datos históricos sin mezclarlos con la temporada actual.

---

# ÉPICA 8 — Favoritos y personalización

### FB-US-036 — Seguir un equipo — P0

**Como** usuario  
**quiero** seguir mis equipos favoritos  
**para** que FutBeat priorice su contenido.

---

### FB-US-037 — Seguir un jugador — P1

**Como** usuario  
**quiero** seguir jugadores específicos  
**para** recibir información independientemente del club donde jueguen.

---

### FB-US-038 — Seguir una competición — P0

**Como** usuario  
**quiero** seguir determinadas competiciones  
**para** encontrarlas fácilmente y recibir contenido relevante.

---

### FB-US-039 — Seguir un partido — P1

**Como** usuario  
**quiero** seguir temporalmente un partido  
**para** recibir sus eventos sin tener que seguir a los equipos.

---

### FB-US-040 — Tener un feed “Para ti” — P1

**Como** usuario  
**quiero** un feed personalizado  
**para** encontrar primero la información que me interesa.

**Puede contener**
- Próximos partidos.
- LIVE.
- Resultados.
- Noticias.
- Transferencias.
- Alineaciones.
- Highlights.
- Videos.

---

# ÉPICA 9 — Búsqueda

### FB-US-041 — Buscar globalmente — P0

**Como** usuario  
**quiero** una búsqueda global  
**para** encontrar rápidamente equipos, jugadores y competiciones.

---

### FB-US-042 — Buscar utilizando alias — P1

**Como** usuario  
**quiero** encontrar un equipo aunque no escriba su nombre oficial  
**para** que la búsqueda sea natural.

Ejemplos:

```text
LDA → Liga Deportiva Alajuelense
Sapri → Deportivo Saprissa
Man Utd → Manchester United
```

---

### FB-US-043 — Resolver entidades provenientes de distintas fuentes — P0 · AUTO

**Como** usuario  
**quiero** que FutBeat identifique correctamente que diferentes nombres corresponden a la misma entidad  
**para** evitar equipos o jugadores duplicados.

---

# ÉPICA 10 — Noticias

### FB-US-044 — Descubrir noticias automáticamente — P1 · AUTO

**Como** usuario  
**quiero** encontrar noticias recientes sin que un administrador tenga que cargarlas  
**para** tener contenido constantemente actualizado.

---

### FB-US-045 — Asociar noticias automáticamente — P1 · AUTO

**Como** usuario  
**quiero** que las noticias aparezcan automáticamente en los perfiles relacionados  
**para** encontrarlas donde espero.

Una noticia puede relacionarse con:

```text
equipo
jugador
competición
partido
transferencia
```

---

### FB-US-046 — Evitar noticias duplicadas — P1 · AUTO

**Como** usuario  
**quiero** evitar encontrar muchas publicaciones sobre exactamente la misma noticia  
**para** mantener limpio mi feed.

**Criterio**
- Agrupar contenido similar mediante `StoryCluster`.

---

### FB-US-047 — Identificar fuente de la noticia — P1

**Como** lector  
**quiero** conocer la fuente original  
**para** saber de dónde proviene la información.

---

# ÉPICA 11 — Transferencias

### FB-US-048 — Consultar transferencias y rumores — P1

**Como** aficionado  
**quiero** seguir posibles fichajes y transferencias confirmadas  
**para** conocer los movimientos de mis equipos.

---

### FB-US-049 — Diferenciar estado del fichaje — P1

**Como** usuario  
**quiero** distinguir un rumor de una transferencia confirmada  
**para** no interpretar información especulativa como oficial.

Estados:

```text
RUMOR
REPORTED
ADVANCED
CONFIRMED
CANCELLED
```

---

### FB-US-050 — Detectar confirmación oficial — P1 · AUTO

**Como** usuario  
**quiero** que una transferencia se marque como confirmada cuando exista anuncio oficial  
**para** conocer su estado real.

---

# ÉPICA 12 — Videos y resúmenes

### FB-US-051 — Encontrar automáticamente highlights — P1 · AUTO

**Como** aficionado  
**quiero** encontrar el resumen del partido una vez publicado  
**para** verlo sin tener que buscarlo manualmente en YouTube.

---

### FB-US-052 — Priorizar fuentes oficiales — P1 · AUTO

**Como** usuario  
**quiero** que FutBeat priorice videos oficiales  
**para** aumentar la confiabilidad del contenido mostrado.

Prioridad:

```text
Canal oficial de competición
Canal oficial del equipo
Broadcaster autorizado
Fuente confiable
Fallback
```

---

### FB-US-053 — Relacionar el video con el partido correcto — P1 · AUTO

**Como** usuario  
**quiero** que el resumen mostrado corresponda realmente al encuentro  
**para** evitar videos incorrectos.

**Criterios**
- Equipos.
- Fecha.
- Competición.
- Canal.
- Título.
- Fecha de publicación.
- Nivel de confianza.

---

### FB-US-054 — Clasificar los videos — P2 · AUTO

**Como** usuario  
**quiero** distinguir el tipo de video  
**para** elegir qué contenido quiero ver.

Categorías:

```text
HIGHLIGHTS
GOAL
FULL_MATCH
PRESS_CONFERENCE
INTERVIEW
ANALYSIS
```

---

# ÉPICA 13 — Fotografías, logos y Media Engine

### FB-US-055 — Mostrar escudo del equipo — P0

**Como** usuario  
**quiero** identificar visualmente los equipos mediante sus escudos  
**para** reconocer rápidamente cada club.

---

### FB-US-056 — Mostrar fotografía del jugador — P1

**Como** usuario  
**quiero** ver una fotografía del jugador cuando exista una fuente utilizable  
**para** identificarlo visualmente.

---

### FB-US-057 — Utilizar fallback cuando no exista imagen — P0

**Como** usuario  
**quiero** que la interfaz siga viéndose correctamente aunque falte una imagen  
**para** que nunca aparezcan espacios rotos.

---

### FB-US-058 — Buscar automáticamente multimedia faltante — P1 · AUTO

**Como** operador de FutBeat  
**quiero** que el sistema busque imágenes para nuevas entidades  
**para** minimizar la intervención manual.

Flujo:

```text
nueva entidad
↓
buscar imagen
↓
validar origen
↓
validar derechos
↓
quality score
↓
asociar
```

---

### FB-US-059 — Seleccionar automáticamente la mejor imagen — P1 · AUTO

**Como** usuario  
**quiero** que FutBeat utilice la mejor imagen disponible  
**para** mantener una experiencia visual de calidad.

---

### FB-US-060 — Actualizar una imagen cuando aparezca una mejor — P2 · AUTO

**Como** usuario  
**quiero** que las fotografías puedan mejorar con el tiempo  
**para** mostrar imágenes actuales y de mayor calidad.

---

### FB-US-061 — Registrar derechos de uso de multimedia — P0 · AUTO

**Como** operador  
**quiero** conocer el origen y derechos asociados a cada imagen  
**para** evitar utilizar material cuyo uso no esté permitido.

---

# ÉPICA 14 — Notificaciones

### FB-US-062 — Recibir aviso de inicio de partido — P1

**Como** seguidor  
**quiero** recibir una notificación cuando comience un partido que sigo  
**para** no perderme el inicio.

---

### FB-US-063 — Recibir notificación de gol — P1

**Como** seguidor  
**quiero** recibir una notificación cuando haya un gol  
**para** seguir el partido incluso con la aplicación cerrada.

---

### FB-US-064 — Recibir resultado final — P1

**Como** usuario  
**quiero** recibir el resultado al terminar un partido  
**para** conocer cómo finalizó.

---

### FB-US-065 — Recibir alineación — P2

**Como** usuario  
**quiero** recibir una notificación cuando se publique la alineación  
**para** conocer los titulares antes del partido.

---

### FB-US-066 — Recibir transferencia confirmada — P2

**Como** seguidor  
**quiero** recibir avisos sobre fichajes confirmados de mis equipos o jugadores  
**para** enterarme rápidamente.

---

### FB-US-067 — Configurar mis notificaciones — P1

**Como** usuario  
**quiero** seleccionar qué notificaciones deseo recibir  
**para** evitar alertas que no me interesen.

Configurables:

```text
Inicio
Gol
Final
Alineaciones
Noticias
Transferencias
Videos/resúmenes
```

---

# ÉPICA 15 — Modo spoiler

### FB-US-068 — Ocultar resultados — P2

**Como** usuario  
**quiero** ocultar resultados de determinados partidos  
**para** poder verlos posteriormente sin spoilers.

**Criterios**
- No mostrar marcador.
- No mostrar eventos que revelen el resultado.
- No revelar resultado mediante notificaciones.

---

# ÉPICA 16 — Uso con conectividad limitada

### FB-US-069 — Consultar contenido reciente sin conexión — P2

**Como** usuario  
**quiero** acceder a determinada información almacenada localmente  
**para** seguir utilizando FutBeat con conexión inestable.

Cache:

```text
favoritos
partidos recientes
tablas
equipos
jugadores vistos
noticias recientes
```

---

### FB-US-070 — Sincronizar al recuperar conexión — P2

**Como** usuario  
**quiero** que la aplicación vuelva a sincronizar automáticamente  
**para** actualizar información obsoleta.

---

# ÉPICA 17 — Calidad de datos

### FB-US-071 — Conservar procedencia de cada dato — P0 · AUTO

**Como** operador de FutBeat  
**quiero** conocer de qué fuente provino un dato  
**para** auditar cualquier inconsistencia.

---

### FB-US-072 — Asignar confianza a los datos — P0 · AUTO

**Como** operador  
**quiero** que FutBeat calcule confianza en información recibida  
**para** decidir automáticamente si puede publicarse.

Estados:

```text
UNVERIFIED
PROVISIONAL
VERIFIED
CONFLICT
```

---

### FB-US-073 — Detectar conflicto entre proveedores — P0 · AUTO

**Como** operador  
**quiero** detectar cuando las fuentes entregan información distinta  
**para** evitar consolidar automáticamente información dudosa.

Ejemplo:

```text
Provider A   2-1
Provider B   2-1
Provider C   1-1
Official     2-1
```

---

### FB-US-074 — Determinar dato canónico — P0 · AUTO

**Como** usuario  
**quiero** que FutBeat seleccione el dato más confiable  
**para** recibir información consistente aunque exist
