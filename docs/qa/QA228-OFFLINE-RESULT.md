# QA228 — ensayo físico offline

Resultado: PASS del modo supervisado offline y de la restauración reversible. No autoriza lectura conectada.

## Evidencia física

Galaxy A32 SM-A325M RF8R32GQWGL. Ensayo 2026-10-31, aproximadamente 03:14–03:22 UTC. Datos reales previamente almacenados; ninguna consulta a producción.

| Componente | Resultado | Evidencia |
|---|---|---|
| Feed guardado | PASS | artifacts/qa228/physical/01-feed.png |
| Everton–Newcastle 3–1, Match Center | PASS | physical/03-match-center.png |
| Titulares, suplentes, fotos y placeholders | PASS | physical/04-lineups-0.png a 04-lineups-4.png |
| Estadísticas desde SQLite | PASS | physical/05-statistics.png |
| Cerrar y reabrir dentro de la misma sesión | PASS | physical/06-reopened-same-session.png |
| STOP explícito | PASS: PID ausente en 1,532 s | stop-result.json |
| Terminación del launcher candidato | PASS: PID ausente en 10,443 s | watchdog-result.json |
| Restauración QA123 | PASS | restore-result.json, rollback.log |

El failsafe independiente PID 29020 confirmó force-stop por heartbeat vencido a las 03:22:22.042 UTC, antes de iniciarse la restauración a las 03:22:22.324 UTC. No se registró ninguna tarea Windows nueva. El guard temporal de rollback fue independiente del proceso que ejecutaba la navegación. No se cerró literalmente el chat: se comprobó independencia de procesos y terminación real del launcher.

## Tráfico y caché

Red física bloqueada durante el ensayo; variante QA con HttpOverrides que rechaza crear clientes antes de abrir sockets y LIVE desactivado. No es una captura de paquetes.

Tres procesos observados: 18600, 24180 y 25208. Cero eventos httpSuccess; respectivamente 38, 3 y 3 creaciones de clientes HTTP bloqueadas. Son intentos bloqueados, no solicitudes completadas. No confundir con ausencia de intentos. No hubo errores Flutter ni RenderFlex en los logs acotados recogidos. Primer recorrido: tres hits SQLite, detalle persistente en 256 ms. Fotografías previamente descargadas visibles sin red. Latencias Android am start -W: 8073 ms, 5324 ms y 4680 ms; no equivalen a tiempos de carga de cada pantalla.

Los datos SQLite conservaron el mismo SHA antes/después de actualizar la variante QA: b31107a2b09629d67759b7e121bf4faa1c7f60648182137d018cc7d343dedd15. Sin desinstalar ni borrar datos; UID y primera fecha de instalación conservados.

## Artefacto instalado

APK debug local-cache-only, paquete com.futbeat.futbeat.qa, versionCode 32, versionName 1.0.0, arm64. Fuente compilada e6df50a; cambios posteriores limitados a utilidades del host. Artefacto original conectado +32 conservado.

- Ruta: artifacts/qa228/futbeat-qa-1.0.0+32-local-cache-e6df50a.apk
- SHA-256: 56785DC431B0706E349639AF1AE35610DF99964225D5A04C798331862DD22280
- Tamaño: 111090592 bytes
- Certificado SHA-256: 6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362
- DEMO=false, QA_LOCAL_CACHE_ONLY=true; OAuth, Push y anuncios desactivados; diagnóstico QA activo.

Esta variante offline permanece instalada. No se ha restaurado ni autorizado la variante conectada.

## Corrección y validación local

Se corrigió que el ledger de la propia sesión se interpretara como otra ventana en competencia. Un ledger ajeno sigue rechazado. Se añadieron contadores de clientes HTTP bloqueados, activación acotada y rollback con restauración de ACL y comprobación del XML original.

42 pruebas de política sintética PASS; cuatro pruebas mock del failsafe PASS; ocho pruebas Flutter focales PASS; flutter analyze sin incidencias. Sintaxis de ambos scripts QA228 sin errores y git diff --check limpio. No se repitió la suite histórica completa.

## Estado final y límites

QA123 Running, heartbeat fresco DISARMED; scripts originales, permisos ACL y XML de la tarea idénticos al backup. Política temporal retirada. App QA sin PID. Conectividad original restaurada después del cierre confirmado: airplane=0, wifi=1, datos móviles=0. Paquete oficial ausente antes/después, sin modificaciones.

No se evaluó salud remota ni se abrió una sesión conectada. Fotografías e identidades se observaron según caché existente; no se verificaron contra proveedor. GO para reutilizar el ensayo offline; NO-GO conectado hasta revisar y autorizar el contrato de lectura sin hidratación y su activación.