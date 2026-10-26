# Issue #222 — comprobación puntual de identidades (solo lectura)

QA81 mostró dos filas para Cartaginés–Puntarenas del 13-10-2026: un 3-1 FINAL y otra «Por confirmar». No se ha demostrado todavía que sean el mismo fixture canónico.

Evidencia local: `F:/FutBeat/recovery-03/QA81-DIAGNOSIS.md` registra el fixture TheSportsDB `fb_match_1672e2b49b604b02b77c7d26f2400a37` (externalId `2488665`), inicio `2026-10-14T00:00:00Z`, SCHEDULED en la exportación del 17-10, Cartaginés `fb_team_car` y Puntarenas `fb_team_6393d42a7e904f28a0f58a028b2b5305`. También registra otro Puntarenas `fb_team_a201b44b15e84b218c01e4cd97ab38b1`, usado por un fixture GOAL del 19-09. No está verificado el ID canónico ni el ID externo del FINAL 3-1.

Para Claude, en una ventana vigente y con límites de producción propios:

1. Leer únicamente los fixtures Cartaginés–Puntarenas del 13-10, incluidos sus IDs canónicos, proveedor/ID externo, equipos canónicos, kickoff, estado y resultado. Limitar la respuesta a los candidatos de ese partido.
2. Leer `provider_entities` y redirects de los dos IDs de Puntarenas y de los equipos que figuren en los dos fixtures; comprobar procedencia y si existe una relación explícita entre identidades.
3. Comparar competición, fecha real, participantes y evidencia de juego antes de concluir si hay un duplicado. No inferir identidad por nombre o escudo.
4. Devolver IDs y campos mínimos, esperado/observado, y clasificación: fixture duplicado confirmado, partidos distintos, o evidencia insuficiente.

Sin escrituras, fusiones, reingestión, GOAL ni cambios de producción. Flutter deduplica por identidades canónicas y no debe fusionar por nombre.
