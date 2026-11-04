# MOBILE269 · candidato Android 1.0

## Consolidación

MOBILE269 se aisló de MOBILE261. La rama parte de MOBILE268 (54e44f4a); MOBILE261 se leyó en ff77b9d. MOBILE259 (92531b60), MOBILE260 (1719ecb6), MOBILE264 (bb79bf70) y MOBILE266 (13912399) son ancestros. MOBILE262 01d2c402 y los cinco parches funcionales de MOBILE263 724409f9, 45928a7f, 9964e928, 4ea156a4 y 5f6f92f5 tienen patch-id equivalente en el candidato. Los commits 8c9e393f y 17b3a143 son evidencia histórica de documentación.

MOBILE261 f020f434, efdb4c97, 01fc21ff y ff77b9d se omiten por equivalencia de parche. ed812a00 combina 7e3b940, 6ffda74 y f92b5b62; comparación directa confirma las mismas guardas en push.dart y auth_flows_test.dart. El único cambio adicional al comparar account_lifecycle_test.dart es el UID del fixture introducido al validar el consentimiento de borrado.

## Regresiones reproducidas

| Requisito | Comportamiento corregido | Origen → integración | Focales |
| --- | --- | --- | --- |
| A09 | Reabrir manualmente el mismo enlace tras un fallo transitorio de verificación. | 7929dfef → 9408ed6b | 98 PASS |
| S01/S07 | Reintentar revalida solo la fecha seleccionada, aunque el calendario parcial siga vigente en caché. | bcd1172c → 2971be1d | 31 PASS |
| M03 | Una actualización incompleta conserva el último contexto válido del mismo partido y lo muestra como guardado. | c36d0bc0 → 88a47254 | 43 PASS |

| A03/A07 | Volver a elegir el país ya guardado completa el marcador de sincronización que falló. | a7e9bc6a → fd0c3b2b | 75 PASS |

Las cuatro regresiones fallaron antes del arreglo. Los análisis focales quedaron limpios. La revisión de recuperación/calendario confirmó que se conservan deduplicación, cancelación y presupuesto existentes. Las pruebas de HTTP usan fixtures locales.

## Android y salida a Internal Testing

- R03/R06: 11 escenarios Gradle offline con valores sintéticos, incluido el grafo de release en dry-run, más rechazo verificado al faltar configuración de firma. Ningún empaquetado. Bloque intermedio 88a47254: 1.950 Flutter PASS, goldens incluidos, analyze limpio.
- R01: applicationId com.futbeat.futbeat. La fuente conserva 1.0.0+16; el versionCode 5 fue propuesto para un empaquetado explícito y necesita revalidación en Play antes de asignarlo. No modificar el código de versión por inferencia.
- R02: el firmante histórico está documentado. Falta cotejar la Upload Key activa con el certificado público y un firmante disponible. No restablecer la clave por defecto.
- R05: guardas locales para UID, concurrencia y consentimiento conservadas. BLOCKED_BACKEND hasta confirmar recibo durable y consulta de estado sin volver a ejecutar el borrado.
- R08/R10: el manifiesto fuente declara INTERNET y POST_NOTIFICATIONS; exporta MainActivity y el callback OAuth. processReleaseMainManifest offline pasó; minSdk 24, targetSdk 36, permiso interno DYNAMIC_RECEIVER_NOT_EXPORTED y ProfileInstallReceiver de AndroidX. Una simulación de 1.0.0 (5) produjo el applicationId y la versión esperados; se restauró la configuración local. Revisar otra vez el manifiesto del AAB firmado. QA física solo con autorización, watchdog y conservación de datos. QA conectada requiere contrato pasivo desplegado, alcance y preflight vigente.
- R09: PR #245 Draft, mobile y contracts SUCCESS en Linux sobre 13912399, run 41851884666. La propuesta de PR MOBILE269 queda lista para autorización; pendiente CI del candidato.
- R04/R11: autorizar publicación del SHA local para CI sin secretos, confirmar certificado público de subida y configuración. Luego generar un único AAB trazable, inspeccionar firma/manifest/versionado/SDK/ABI/16 KB, ejecutar QA del artefacto autorizado y confirmar checklist de Internal Testing antes de subir. RC NO-GO hasta verificar esos puntos.
