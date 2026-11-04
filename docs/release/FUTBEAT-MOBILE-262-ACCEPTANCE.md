# MOBILE262 — aceptación local y handoff RC

Base de integración: da997361c6454e0c43a8eab865105744a84ca775. Rama aislada codex/mobile-262-personalization. MOBILE261 estaba ACTIVE, con 4 intentos, 1 completado y 3 bloqueados al iniciar. R05 figuraba en cola y el worktree de MOBILE261 estaba libre de su bloqueo. Las dos líneas pueden continuar por separado.

| Requisito | Resultado local | Aceptación pendiente |
| --- | --- | --- |
| A01–A07 · Bienvenida, configuración rápida, país, equipos, competiciones, jugadores y cuenta | Recorrido de widgets completo hasta Partidos como invitado. Costa Rica aparece para región CR y la selección manual persiste al reabrir con región US. Se reconstruyen router, servicio y contenedor sobre SQLite de archivo. | Recorrido en el artefacto exacto en Android y acceso a cuenta real autorizado. |
| A04–A06 · Sugerencias y búsqueda | Las pruebas de relevancia cubren selección, ligas nacionales y clubes internacionales. El contrato local de sugerencias consulta plantillas existentes, incluidas selecciones seguidas si hay membresía. La búsqueda de jugadores muestra exclusivamente el snapshot de la consulta y deduplica por ID. Antes, una respuesta vacía mostraba jugadores de las sugerencias. Al limpiar el campo regresan las sugerencias. | Confirmar cobertura del catálogo desplegado y respuestas reales en una sesión autorizada. |
| M02/A07 · Favoritos y personalización | Alta, baja y nueva alta del equipo, y alta de liga/jugador. Tras reabrir SQLite quedan tres filas únicas. Desde Perfil se accede a las tres categorías. Las regresiones del feed cubren Favoritos y liga con una aparición por grupo, incluidos IDs redirigidos y homónimos. | Confirmar el recorrido en el dispositivo con el candidato exacto. |
| N08 · Alertas | Inicio, gol, final, roja, titular y banca se pueden editar como invitado y se recuperan tras reabrir. Los seis controles reaparecen en Perfil. Titular y banca están disponibles sin cuenta ni suscripción en el recorrido. | Entrega real sin verificar. Conservar FCM en dry_run. |
| A07/A09 · Aislamiento | Las regresiones integradas cubren vinculación desde invitado, cambio de cuenta, escrituras fallidas, recuperación y procedencia de favoritos. Se usó SQLite nativo local y dobles de auth y almacenamiento seguro. | Auth real y reinicio físico pendientes. |
| R05 · Borrado | Recuperación local cuando la confirmación queda persistida. Si falla la primera escritura tras confirmar el backend simulado y se recrea el servicio, el estado sigue NO CONFIRMADO. La regresión exige distinguirlo de un 401. | MOBILE261 conserva R05 en su cola. El requisito de borrado permanece abierto. |
| Ciclo de vida | La suite incluye transiciones simuladas de pausa y reanudación. La prueba de onboarding cierra y reconstruye el entorno local. | Ciclo de vida en Android y proceso real pendientes. |

Evidencia local en artifacts/mobile262. search-before.log conserva el fallo de búsqueda. focal-final.log registra 116 pruebas aprobadas. full.log y analyze.log contienen la verificación del conjunto.

RC NO-GO. Quedan la firma y configuración de release, el CI del candidato y la aceptación en el artefacto exacto, con autorización específica para las comprobaciones conectadas. Antes de integrar, comparar MOBILE262 con el HEAD vigente de MOBILE261 y verificar el solapamiento en onboarding y cuentas. No hay un binario nuevo en este bloque.

Código verificado: 01d2c4024c80291d992b6f1858dd4e2fab3bc526. Suite Flutter: 1932 aprobadas, incluidos goldens. Flutter analyze: 0 incidencias (11,5 s).
