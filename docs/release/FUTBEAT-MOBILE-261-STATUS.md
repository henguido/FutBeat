# MOBILE261 — operación local en curso

Base1719ecb647f55d0597cedc130b328f9fab62749e; integración codex/mobile-261-integration @ 24df0b60ed6335dede5477d2c92b857cc81a63cc. Sin cambios a main o worktrees Claude. Único orquestador root; tres agentes paralelos en worktrees auth/feed/match. Registros operativos completos: F:/FutBeat/recovery-03/mobile-261/.

## Primer requisito de entrega

PR Draft244: https://github.com/henguido/FutBeat/pull/244 . Basecodex/mobile-252-release07a54b25, HEAD1719ecb. Push normal verificado. CI Linux run41733921175 SUCCESS. Mobile:codegen/analyze0avisos y1731testsportablesPASS; workflowexistente excluyevisual_test.dart(6casos). Windows2601737PASSincluyó esosgoldens. ContractsjobSUCCESS por No backend checks needed; npmtest/checkomitidos,no atribuirlos como ejecutados. Ningún merge/despliegue.

## Cola de requisitos

| Tarea | Prioridad | Responsable | Estado | Evidencia / aceptación local |
|---|---|---|---|---|
|261-R09 / R09|P0|root E/F|CI_PASS para260|run41733921175, SHA1719ecb;261nuevoaúnsinCI|
|261-D1 / S03/S07|P0|root D|LOCAL_PASS|replayREST/WebSocketlocal2FAILantes,34focalesPASS/analyze0;conservarúltimaobservación|
|261-B1 / M02/M03|P1|feed258|LOCAL_PASS|precarga interrumpida2FAILantes;14focalesPASS;0HTTP/presupuesto8conservado|
|261-C1 / M09/#217|P1|match258|LOCAL_PASS|suplente entrante omitidoFAILantes;30focalesPASS;IDsdeincidenciaQA225guardada,metadatoscontrolados|
|261-C2 / M04/M09|P1|match258|LOCAL_PASS|extraMinuteomitidoFAILantes;30focalesPASS|
|261-C3 / M04/M09|P1|match258|LOCAL_PASS|aliascanónicodelrosterdeja sinpanellocalFAILantes;56focalesPASS/negativosambigüedad|
|261-A1 / A07/A09/N08|P0|auth258|LOCAL_PASS|fallolecturaIOseconvertíaendefaults,4FAILantes;263focalesPASScon11casosnuevos/analyzelimpio|
|261-A2 / A07|P0|auth258|IN_PROGRESS|IOdemarcadordirtysobrescribedatoslocales:4FAILantes,fixenvalidación|
|261-D2 / M03|P1|feed258|IN_PROGRESS|empatedetimestampsenevicciónSQLite:reproducciónpendiente,noafirmarbugtodavía|
|261-C4 / M04/M09|P1|match258|IN_PROGRESS|dosversionesmismoIDresucitangoalanulado:2FAILantes,fixenvalidación|
|261-RC / R01-R10|P0|root E|BLOCKED|certificadoupload/configaprobada/artefactoexacto/QAreal/contratoconectado/distribución|

Suite cruzada1:15PASS;cruzada2:13PASS. Suite completa del bloque24df0b6: **1764/1764 PASS**,168s, goldens incluidos. No se modificaron referenciasPNG. No QA física/conectada, OAuth real oFCM real;FCMnoactivado. Ningúnbuildnuevo.

## Continuidad autorizada

Una única automatización ACTIVE: futbeat-mobile261-reanudaciones-locales-limitadas, HOURLYCOUNT24;STOP2026-11-04T22:49:30Z. Verificada porherramientayTOML. Bloqueoatómico impideediciónsimultánea; no eliminarlockajeno. Noautoriza producción,teléfono,builds,push niPR. No garantiza24hefectivas. Límitesconsultadosreadonly:75%disponibleenventanasemanalcompartida; sinconsumirreinicios/créditos.

43issuesiniciales,20abiertos,0cierresremotos. LOCAL_PASSnoequivaleDONEreal. Ninguna referenciaPNGmodificada. Publicación261pendiente deautorización;mantener260PRexacta.

## Commits nuevos locales

```
f4272a43 fix(live): preserve newest observations across REST and Realtime replay
b9e85f6d fix(player-profile): retain incoming substitutions as match participation
895916ab fix(player-profile): order stoppage-time activity by extra minutes
9a0f301a fix(feed): resume interrupted stored favorite warming
32ca336d fix(match-center): reuse canonical roster aliases for local player panels
87a717a7 test(feed): verify retry navigation and live SQLite favorite changes
52067c61 test(feed): keep retry acceptance lint clean
2fa728f6 test(feed): cover warm ownership and SQLite errors across resume
24df0b60 fix(profile): preserve preferences when local storage cannot be read
```
