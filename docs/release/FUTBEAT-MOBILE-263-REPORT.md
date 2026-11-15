# FUTBEAT MOBILE263 — informe de integración

Inicio observado: 2026-11-04 05:33:58 UTC. Base `1f2f4a969bfc1376b2629ca27bb44b81abd8f2ff`, equivalente al árbol de código probado en MOBILE262 `01d2c402`. Rama única de consolidación `codex/mobile-263-integration`. MOBILE261 fue pausada con autorización, conservando su automatización, ledger de 5 intentos y límite original. MOBILE262 se conserva como rama independiente.

## Responsabilidades

| Rol | Participante | Worktree |
| --- | --- | --- |
| A · Cuentas | auth258 | mobile-263-accounts |
| B · Feed y favoritos | feed258 | mobile-263-feed |
| C · Match Center | match258 | mobile-263-match |
| D · LIVE y orquestación | root | mobile-263-integration |
| E/F · RC y QA integrada | root | mobile-263-integration |

## Defectos y evidencia

| Requisito | Comportamiento reproducido | Corrección local | Evidencia |
| --- | --- | --- | --- |
| S02/S07 | Tras cambiar de partido, una respuesta REST del alcance anterior se aplicaba antes de la reconexión con debounce. | Verificar el conjunto de IDs activo al recibir REST antes de reconciliarlo. `724409f`. | 1 FAIL antes, 48 PASS después, analyze limpio. Logs live-before.log, live-after.log y live-analyze.log. |

## Estado de Release Candidate

**NO-GO.** La fuente declara el paquete oficial `com.futbeat.futbeat` y la variante QA usa un sufijo distinto. `pubspec.yaml` registra `1.0.0+16` como dato de fuente, sin acreditar disponibilidad en Play. El código efectivo de un artefacto puede venir de la compilación. Verificar el siguiente versionCode en todos los tracks antes de congelarlo.

| Bloqueador | Evidencia requerida |
| --- | --- |
| R01/R02 · Versión y firma | Confirmar versionCode disponible y coincidencia SHA-256 del certificado público de subida activo con el firmante del AAB oficial. |
| R03/R04/R06/R07 · Configuración y artefacto | Aprobar los defines oficiales, mantener las guardas release, verificar paquete, permisos, integridad, dependencias nativas, firma y SHA del artefacto exacto. |
| R09 · CI Linux | Ejecutar CI autorizado para el HEAD definitivo. El verde anterior de MOBILE260 corresponde a otro SHA. |
| R08 · Dispositivo | Evidencia del A32 con el artefacto exacto, READY, aislamiento y cierre confirmado. |
| R10 · Contrato conectado | Confirmación de las rutas desplegadas sin hidratación y autorización específica. |
| R05 · Borrado | Tras perder la confirmación antes de persistirla, el reinicio sigue NO CONFIRMADO. Requiere evidencia durable ligada a la operación o verificación autorizada. |

## Integración verificada

| Requisito | Defecto local reproducido | Fuente → integración | Pruebas focales |
| --- | --- | --- | --- |
| A09 · Recuperación | Rechazar un enlace nuevo dejaba que el formulario anterior cambiara la contraseña e iniciara sesión. | `956df6f` → `45928a7`. Invalidar la sesión de recuperación anterior al comenzar un enlace de reemplazo. | 1 FAIL antes, 94 PASS con dobles locales, analyze limpio. |
| M03 · Contexto parcial | Una respuesta sin un equipo quitaba el partido del snapshot y reemplazaba un detalle abierto por «Partido no encontrado». | `8c54640` → `9964e92`. Conservar el partido exacto de la ruta marcado como guardado y aceptar el contexto completo posterior. | 1 FAIL antes, 37 PASS, analyze limpio. |
| S07/M01 · Filtros | Con datos guardados, un filtro vacío omitía el aviso de caché y parecía una afirmación sobre el calendario actual. | `35f0ff4` → `4ea156a`. Mantener el aviso y explicar que el filtro quedó vacío en los datos guardados. | 1 FAIL antes, 40 PASS, analyze limpio. |

Los commits de los agentes se incorporaron por parche revisado. Se verificaron ascendencia, archivos permitidos, ausencia de duplicados y equivalencia de patch-id. El agente C hizo además la revisión F de los cuatro cambios. El agente B verificó los requisitos E de release en las fuentes y registros locales. La validación conjunta de Flutter corresponde al SHA que figura en artifacts/mobile263/tested-head.txt.

Para reanudar, abrir la rama de integración de MOBILE263 y comparar el HEAD vigente de MOBILE261 antes de trasladar cambios adicionales. La corrección MOBILE262 ya está en la base. La publicación para CI del candidato requiere autorización separada. Con CI e identidad/configuración aprobados, queda autorizar una compilación oficial y verificar el artefacto exacto antes de solicitar la subida.

## Checkpoint de QA

Primer conjunto integrado: `4ea156a4628d71d95db23c6aa22daca966141c2a`. Suite 1934 PASS, 1 FAIL en una prueba de calendario sin cambios de producción. El test daba por hecho que transcurridos 30 ms habría exactamente una emisión. Con el host cargado ya había emitido la caché y su estado tras error. `5f6f92f` usa la primera emisión como barrera y comprueba el marcador, la revalidación y el estado guardado después del fallo. La repetición focal de las cinco áreas dio 161 PASS. Los logs iniciales se conservan.

Segunda pasada de agentes: A delimitó la ventana entre el PUT de recuperación y la instalación de sesión durante preparación local. B identificó el caso de fecha vacía con cobertura parcial y snapshot fresco. Windows dejó ambas reproducciones inconclusas. C no encontró un caso reproducible de alias de partido que justificara un cambio. Los tres casos quedan sin nuevos parches. Al reanudar, verificar primero si existe el borrador de A y reproducir bajo barreras deterministas.

Cierre UTC: 2026-11-04T06:02:51.6531802+00:00. Ventana observada: 28.9 min, incluidos coordinación, pruebas e interrupciones de Windows. No se midió tiempo efectivo separado y no se sumaron minutos de agentes concurrentes. No se alcanzó el primer checkpoint de 60 minutos efectivos. Los tres agentes terminaron sus pasadas.

HEAD de código y pruebas: 5f6f92f529594ec45a1225a4a45ad21165079965. Segunda suite: 1934 PASS, 1 FAIL, incluidos goldens. El caso de calendario corregido pasó. El caso de cierre de sesión agotó el timeout de 1 s. Pasó en los 161 focales y en la repetición aislada posterior. El primer intento aislado coincidió con la suite y falló al abrir la DLL SQLite. Los registros se conservan. El timeout no tiene causa confirmada y la suite completa queda sin aprobación. Flutter analyze: 0 incidencias sobre el mismo código y pruebas. Logs full.log, full-retry.log, final-focal.log, final-analyze.log y logout-isolated-final.log en artifacts/mobile263.

Se reactivó la automatización existente de MOBILE261 al terminar la pausa autorizada, con el mismo ID, plazo y límite. Para retomar MOBILE263, verificar el timeout de logout con una suite serial y evaluar el borrador del caso A antes de modificar código. Mantener RC NO-GO.
