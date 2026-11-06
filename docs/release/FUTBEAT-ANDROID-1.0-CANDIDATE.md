# FutBeat Android 1.0 — candidata consolidada

Base: `7e7834b3b96ca0e29d6defb9cbc94f55dd4ac4b0`, PR #247. Rama única: `codex/android-1-release-candidate`. Sin merges ni incorporación indiscriminada de PR históricas. La base ya conserva autenticación, recuperación, favoritos por cuenta, personalización, alertas, SQLite y diseño FutBeat. Las aceptaciones físicas anteriores pertenecen a esa base, no acreditan el nuevo binario.

## Correcciones vinculadas al roadmap

- S01/S02/M03: la tercera lectura inicial de Match Center esperaba incorrectamente que existiera un hueco libre y se rechazaba mientras detalle y previa ocupaban los dos. Regresión reproducida antes. Ahora espera un máximo total de ocho segundos, se cancela al cerrar/salir y conserva 30 consultas/15 minutos, 8/minuto y 2 simultáneas. La caché fresca se entrega sin esperar red. No se añaden reintentos ni endpoints.
- R10/M03: Noticias desaparece de la navegación pasiva, cuyo router ya excluía esa función. Índices y destinos permanecen alineados; navegación oficial conservada.
- M03/R10: el bloqueo global de HTTP de Preview impedía descargar fotografías aunque la API devolviera URLs. El descargador existente admite únicamente HTTPS, puerto 443, host exacto `media.goal-api.com` y rutas estáticas `/badges/{players,teams,tournaments}/archivo.{png,jpg,jpeg,webp}`. Sin credenciales, consultas, fragmentos, API del proveedor ni redirecciones fuera de esa lista. No envía la clave Preview. Conserva identidad canónica+URL, placeholder, validación de imagen, 2 MB por descarga, 15 segundos, disco privado de 32 MB/400 entradas/7 días. Dominios adicionales requieren evidencia y una ampliación explícita.
- M03: ausencia de alineaciones/estadísticas mantiene los estados de cobertura existentes; no se crean jugadores, incidencias ni estadísticas. El encuentro observado físicamente tenía cero titulares y cero estadísticas en el detalle guardado; es cobertura, no prueba de datos perdidos.
- R03: empaquetado oficial rechaza banderas Preview y cualquier `FUTBEAT_PASSIVE_CLIENT_KEY` no vacía. Solo comunica el nombre del problema, nunca su valor.

## Acceso oficial propuesto: decisión de contrato, sin nueva arquitectura

La clave revocable compartida está limitada a Preview; no es autorización individual y puede extraerse de su APK. No se trasladará al release oficial. Reutilizar la API central de lectura y SQLite, con contrato de producción aprobado por backend: JWT público de usuario verificado por servidor para lectura personalizada; identidad y autorización por usuario para favoritos/cuenta; lectura de invitado limitada explícitamente; límites globales y por identidad/IP aplicados en servidor; sin demandas de proveedor por navegación. Las actualizaciones/ingesta siguen separadas de lecturas. No usar service_role en móvil ni conceder acceso por parámetros de cliente. Falta la decisión y evidencia de Claude para ese contrato oficial; el smoke de Preview no la sustituye. No hay cambios de backend en esta rama.

## Controles de Google Play pendientes

| Control | Resultado | Acción mínima |
|---|---|---|
| Paquete oficial | Fuente `com.futbeat.futbeat`; Preview con sufijo separado | Verificar manifiesto del AAB exacto cuando pueda compilarse |
| Upload Key | NOT VERIFIED contra Play | Obtener certificado público de Upload Key y compararlo con el keystore aprobado; no generar ni restablecer claves |
| Firma histórica local | C9:D4:5B:74:C4:7F:2B:8F:81:6B:A6:1F:14:76:F3:BC:C1:76:D9:6C:54:20:4E:A9:B3:E6:79:F8:0D:9E:4F:4F, evidencia previa | La lectura pública sin contraseña no permitió nueva extracción; integridad y disponibilidad de firma actuales pendientes |
| Play App Signing | D3:07:B7:E2:F9:D3:99:FA:3C:6C:C3:14:B6:DE:B0:01:39:B3:F6:09:A9:6B:87:EB:FB:76:48:12:D1:0D:CD:E4 visible en Console | Es otro certificado; no confundir con Upload Key |
| Versión | Propuesta 1.0.0 (5), no aplicada | Confirmar códigos utilizados en todos los tracks antes de aprobar |
| Configuración oficial | BLOCKED | Aprobar endpoint/contrato, claves públicas, flags y procedencia; sin clave Preview |
| Google/correo/reset/sesión | LOCAL_PASS con dobles y regresiones existentes; proveedor real NOT VERIFIED | Recorrido autorizado con callbacks y certificado distribuido |
| Facebook | Deshabilitado hasta configuración y aceptación | Conservar botón ausente mientras no esté aprobado |
| Notificaciones | Preferencias locales y aislamiento cubiertos; entrega real NOT VERIFIED | Mantener dry_run; aprobar Firebase y aceptación antes de afirmar entrega |
| AdMob | Guardas rechazan unidades de prueba cuando hay anuncios; configuración oficial no congelada | Aprobar monetización o anuncios apagados; inspeccionar manifest fusionado y metadatos sin IDs de prueba antes de empaquetar |
| R05 borrado de cuenta | BLOCKED_BACKEND | Recibo durable + consulta de estado; no afirmar éxito ni repetir borrado incierto |
| Privacidad/permisos/SDK | Fuente conservada; aceptación final pendiente | Comparar manifiesto fusionado, SDKs y Data Safety/política aprobada del binario exacto |
| AAB oficial | NO GENERADO / NO-GO | Cerrar firma, configuración, contrato y aceptación antes de construir; no subir/distribuir |

## Evidencia

Pruebas locales y resultados finales en `artifacts/android-1-rc/` (excluidos de Git). Los goldens no se modifican. La regresión inicial fallida está en `context-before.log`; 69 focales y dos pruebas de navegación pasiva pasan. Analyze PASS (cero incidencias) y suite completa 1.997 PASS / 0 FAIL / 3 omitidas por flags de variante, incluyendo goldens existentes, 185 segundos. Las dos pruebas específicas de Preview se ejecutaron aparte con sus banderas y pasaron. CI Linux del HEAD se registra por separado. Los resultados físicos previos están en `mobile-278-integration/artifacts/preview-physical/RESULT.md`; las correcciones nuevas necesitan aceptación del artefacto exacto. Sin modificaciones productivas, GOAL, QA123 ni instalaciones oficiales.
