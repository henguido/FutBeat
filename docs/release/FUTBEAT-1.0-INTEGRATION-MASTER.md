# FutBeat 1.0 · tablero de integración

## Línea de integración

Usar exclusivamente `codex/android-commercial-qa` en `artifacts/android-commercial-qa` para cambios Android de esta misión. El checkout comercial y la RC pertenecen a un repositorio Git superficial independiente del checkout principal. El código de Billing, FPD y sus pruebas locales se conserva fuera del alcance de la salida gratuita. La configuración aprobada para la primera aceptación mantiene compras, anuncios, Facebook, push y FPD apagados. Activar AdMob en una candidata distinta requiere volver a comprobar la configuración release, UMP y la ficha Play.

| Componente | Ubicación | Estado | Integrado | Pruebas | Acción |
| --- | --- | --- | --- | --- | --- |
| main remoto y local | Repositorio principal | LISTO | Remoto e3e6e29b; local 4dccfe5c es su padre | git ls-remote y git show | Mantener protegidos |
| PR Android #248 | aa5b5d115f1ebc913bcb5ed70afd3acbf72414d6 | REQUIERE CORRECCIÓN | Abierta; base remota e3e6e29b, 482 commits adelante y 0 detrás según GitHub | Mobile y rc-focal PASS; Contracts FAIL | Evaluar contratos sobre candidata exacta |
| RC deportiva | codex/rc248-local-candidate en rc248-reconcile, 13919679cc49426f9a133db2edc3822dab1a9c7a | LISTO PARA INTEGRAR | Ancestro del worktree comercial, once commits sobre #248 | Antecedentes físicos OAuth, favoritos, Match Center, offline y R05; obligatoria validación del binario final | Usar como referencia y conservar checkout |
| UTC PR #242 | a19080f1 y 3c65b46 | LISTO | Ambos tienen patch-id estable f72c09f7e6f5bd2a73bdba1298383df964be4413 | Comparación local | Incorporado en la RC; omitir duplicado |
| PR #243–245 y #234–235 | Cadenas Android históricas abiertas | POSPONIBLE | Sin equivalencia completa confirmada | Inventario GitHub | Comparar por defecto concreto antes de traer parches |
| PR #246–247 | Preview offline y pasiva | POSPONIBLE | Abiertas | Inventario GitHub | Fuera del recorrido gratuito normal |
| PR #233 y #236–241 | LIVE, tablas, calendario, cuotas y API | POSPONIBLE | Abiertas; no se asumió equivalencia | Inventario GitHub | Comparar solo si aparece defecto sobre RC |
| PR #7, #47, #219 | Backend histórico y limpieza | POSPONIBLE | Abiertas | Inventario GitHub | Preservar |
| Claude BE11 PR #249 | b6a8b13768618b290d37924155d6b52ef883db16 | POSPONIBLE | Abierta; no requerida para compilar | Estado de PR | Claude controla integración y despliegue |
| BE14 SQL / Edge / republicación | F:/FutBeat/recovery-03/be14; worktrees be14-contract y be14-edge | BLOQUEADO | SQL GREEN 24h según handoff; Edge y backfill sujetos a compuertas | Regresiones Android VERIFIED y correcciones tardías | Esperar autorización específica y compatibilidad del binario distribuido antes de republicar |
| UMP / anuncios | Worktree comercial, 6d14521 y cambios locales | POSPONIBLE | UMP probado en QA; configuración Internal actual sin anuncios | Antecedente físico UMP y banner de prueba | Conservar separado del primer artefacto gratuito |
| Billing y FPD | Worktree comercial y worktree premium-fpd de Claude | BLOQUEADO | QA y prototipo local; release sin gateway; FPD apagado | Revocación QA aprobada; staging TLS y PostgreSQL real pendientes | Reservar para versión posterior con autorización |
| Visibilidad Premium | commit 7ef08871f6dcf10004a424540302bf8a7716cbae | LISTO | Perfil y ruta protegidos por gateway y catálogo | analyze limpio; 170 focales | Validar en APK deportiva integrada |
| Firma Play | FUTBEAT-1.0-UPLOAD-ACTIVATION.md | BLOQUEADO | Activación prevista 26 nov 2026, estado actual sin confirmar | AAB de inspección anterior utiliza otra clave | Verificar certificado activo y versionCode disponible en Play |

### Inventario Git y límites

El repositorio principal registra 247 worktrees, 232 asociados a ramas y 15 detached. El repositorio superficial de la RC registra cuatro worktrees adicionales: RC, comercial y dos snapshots detached de aa5b5d1. Se preservan todos. El checkout principal está en fix/calendar-day-subbatches y tiene trabajo sin seguimiento. La RC presenta utilidades y artefactos locales sin seguimiento. El worktree comercial conserva cambios rastreados y prototipos nuevos en Android, Billing, Premium FPD y backend. Solo se versionó la corrección de las dos pantallas. La comparación del remoto con PR #248 se obtuvo de GitHub porque el límite superficial de aa5b5d1 impide resolver merge-base local. No se certificó equivalencia de cada rama archivada ni se incorporaron parches adicionales.

### Dependencias, orden y rollback

1. Validar la candidata gratuita con API deportiva existente, sesión de usuario, OAuth y R05. Confirmar la configuración pública y el aislamiento del paquete QA.
2. Acreditar Flutter, Contracts y recorrido físico sobre el artefacto exacto. Resolver discrepancias antes de firmar.
3. Verificar target 36 o superior en el manifiesto, App Links con certificado de distribución, OAuth release, política de privacidad, eliminación y declaraciones Play.
4. Cotejar huella completa de upload activa y disponibilidad del versionCode. Ejecutar Build-FutBeatOfficial.ps1 desde un snapshot limpio verificable. Someter AAB a inspección de firma, manifiesto y SHA. Solicitar autorización de subida tras entregar el artefacto.
5. Instalar la versión que entregue Internal Testing y verificar recepción de VERIFIED antes de considerar republicación. Promoción requiere aprobación independiente.

Si falla la integración local, revertir únicamente el commit de interfaz en la rama comercial. Conservar la RC, los cambios locales de Billing y los artefactos identificados. Para Play, detener la promoción o rollout y preparar una compilación correctiva con código superior si ya se distribuyó. Las operaciones BE14 tienen rollback independiente bajo Claude.

| Hito | Estado | Evidencia | Bloqueo | Próxima acción |
| --- | --- | --- | --- | --- |
| M1 | En curso | Inventario, ramas clave, PR, CI, comparación y patch-id | Equivalencias históricas pendientes de relevancia concreta | Revisar solo dependencias que condicionen 1.0 |
| M2 | En curso | Corrección Premium versionada y 170 focales PASS | Contracts remoto FAIL, árbol comercial contiene trabajo pendiente | Validar y aislar insumos exactos de la candidata |
| M3 | En curso | A32 autorizado visible vía ADB; antecedentes deportivos | Recorrido completo pendiente sobre APK integrada | Compilar, verificar y probar la variante aislada |
| M4 | Bloqueado | Procedimiento de firma y config pública con SHA registrado | Certificado activo y código 16 por confirmar; falta aceptación exacta | Verificar Play y firmar únicamente al pasar las compuertas |
| M5 | Bloqueado | Paquete com.futbeat.futbeat documentado | AAB oficial y autorización de primera subida | Internal Testing y prueba de binario distribuido |
| M6 | Bloqueado | Health BE14 SQL histórico GREEN | Aceptación Internal Testing y autorización de publicación | Rollout supervisado y métricas |

### Evidencia de aceptación en curso

- APK universal local: artifacts/FutBeat-1.0-integration-qa.apk, SHA-256 B216DCA0679A3418F683F9353E46E023FB854370D0CDBDF39C180EAFFE4BBAF1. Paquete com.futbeat.futbeat.qa, 1.0.0 (16), target 36, firma debug SHA-256 6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362, callback QA presente. Es diagnóstico del árbol comercial con cambios locales; el diff rastreado sobre HEAD se identificó con d7f2d13c51bd5ed855eb52af998499f15cc05267 y no identifica archivos sin seguimiento. No acredita aún un snapshot release reproducible.
- Flutter analyze limpio, 170 focales y seis goldens PASS. La primera suite completa concurrente se interrumpió tras un crash JIT de Flutter. Reintento serial en curso. Contracts rastreados en ejecución; el primer fallo de caché histórico pasó al repetirlo en aislamiento. Los demás fallos aún requieren clasificación.
- A32: el paquete QA no estaba instalado. Streaming no completó; la transferencia no streaming avanzó de 5,9 a 30,7 MB sin modificar los otros paquetes. Se inició compilación arm64 para reducir la transferencia.
- El AAB de inspección 99A1A5AA2C2A585A9AC18823DA7D8910F12AF4E18470F33A323DB7B1A7C469E4 corresponde a 5663cc6 y una clave anterior. No acredita la línea actual. El APK QA sí cumple el target API 36 exigido por Google Play desde agosto de 2026.
- Checkpoint de esta ejecución: segunda compilación arm64 sin split produjo un APK de tamaño comparable al universal. Se inició un split por ABI para abordar la transferencia. La suite serial superó el punto de caída JIT; Contracts mostró otros fallos aún sin diagnóstico definitivo. Mantener M2 y M3 abiertos hasta que terminen las pruebas y el A32 complete el recorrido.

### Continuación de APK y release

- Snapshot fuente extraído con git archive desde 20c39ec8c982a6e7498362bfb59890bb2489f618, sin cambios locales de Billing o FPD. Configuración pública de Internal previamente aprobada, Flutter pub offline y split arm64 de SDK 36. APK deportiva FutBeat-1.0-20c39ec-qa-arm64.apk SHA-256 6276C506C0FFF87D340CDDA52C1D5677412B140D5D49AC9CBCAE89566CC3C047. Paquete com.futbeat.futbeat.qa, 1.0.0 (2016), firma debug y callback QA comprobados. El código 2016 es el ajuste del split y el AAB oficial base conserva 16. El A32 instaló y devolvió el mismo SHA.
- Android cerró QA con USB incluso usando am start directo. exit-info identifica USER REQUESTED / FORCE STOP y PIDs emisores distintos del proceso FutBeat. wait_for_debugger=0 y debug_app=null. El muestreo no capturó la identidad del emisor. El propietario confirmó que la primera APK de aceptación permanece abierta sin USB. No cambiar aplicación ni controles Android hasta identificar el emisor. Recorrido esencial pendiente sobre el binario exacto.
- Suite serial del árbol de trabajo: 2.105 PASS, 6 SKIP, 0 FAIL. El árbol limpio pasó analyze. Contracts anterior: 1.312 PASS, 8 FAIL, 1 SKIP, 2 TODO. Siete fallos de memoria inicializando PGlite y uno por ID FPD no versionado. Reintento de ocho archivos sobre snapshot limpio en serie: 56 PASS, 0 FAIL. Suite completa del snapshot en curso.
- Publicidad QA: FutBeat-1.0-20c39ec-ads-qa-arm64.apk, com.futbeat.futbeat.commercialqa 1.0.0 (2016), SHA-256 5E8FD8C1731B20866E6A82FED7453ACD739035093F5E3EA81756AC861CA3FF52. App ID existente en manifiesto, UMP y banner de prueba, catálogo Premium ausente. Falta aceptación física del binario. app-ads.txt HTTP 200 y línea esperada. App Links HTTP 200 y entrada de paquete oficial con dos huellas; pendiente cotejo contra Play.
- AAB de inspección del snapshot: FutBeat-1.0-20c39ec-inspection-NOT-FOR-PLAY.aab, SHA-256 6C4B4444B8376C4782587BFC57F634CEB78B0479BED6853F85A685A0E8B3E56A. Validado con bundletool y jarsigner, firma temporal de inspección eliminada, com.futbeat.futbeat 1.0.0 (16), target 36, min 24, OAuth oficial y enlace /auth/reset. Configuración sin anuncios ni Premium. Firma upload activa y disponibilidad de 16 todavía no confirmadas en Play.
- Dependencias de Claude: BE18 dry OK sin cambio a 11:47 CST del 14 nov; BE17 informe local no aplicado. BE14 Edge sigue separado. No usar los pendientes deportivos de backend como defectos Android sin correlación de evidencia.
