# MOBILE259 — cierre funcional local Android1.0

## Resultado

Continuación de455c9094, en rama aislada `codex/mobile-259-integration`. Siete defectos reproducidos y corregidos, sin modificar producción, teléfono, main, configuración de firma, dependencias ni artefactos APK/AAB existentes. La matriz única está en `docs/release/FUTBEAT-DEFECT-MATRIX.md`:43 issues (20 abiertos),52 requisitos del roadmap y27 registros históricos contextualizados. No se cerró ningún issue remoto.

## Correcciones

| ID / requisito | Problema comprobado | Corrección / commit integrado | Evidencia local |
|---|---|---|---|
| D259-01 / S03/S05/M03 | Detalle anterior restauraba gol anulado y estadísticas antiguas en SQLite |14e65806 compara fetchedAt válidos antes de fusionar memoria/disco | Fallo original en detail-order-before.log; regresión memoria+SQLite y85 pruebas de integración PASS |
| D259-02 / M09/#157/#222 | Perfil reutilizado mostraba páginas/respuestas del equipo anterior |1eccf119 limpia páginas y cambia generación al cambiar team.id |2FAIL en host real NestedScrollView antes; pruebas almacenadas/pendientes PASS después |
| D259-03 / S02/S03 | DELETE Realtime atrasado borraba revisión más reciente |ed2fb338 exige que borrado no demuestre revisión/timestamp anterior | Regresión expected2/actualnull antes;55 focal PASS; DELETE vigente y solo PK preservados |
| D259-04 / M04 | Segunda amarilla desaparecía de expulsión, minutos, resumen e icono |afe48906 contempla SECOND_YELLOW_CARD/YELLOW_RED_CARD |4FAIL antes; casos titular/suplente y regresiones Match Center PASS |
| D259-05 / M04/M09/#217 | Panel descartaba eventos si jugador solo tenía identidad canónica explícita |aaceb4bc compara IDs canónicos actor/asistente; conflictos no se resuelven por proveedor/nombre | Fallo antes;61 focal PASS incluyendo identidad y cronología |
| D259-06 / A03/A07 | Guardado de formato horario terminado tras salir usaba WidgetRef desmontado |fc3f96e0 comprueba pantalla activa | Excepción StateError reproducida antes; prueba de cierre PASS después |
| D259-07 / A03/A07 | Error local/sync quedaba sin manejar o selector mostraba valor no guardado |d3c6f6b5 recupera valor local y mensaje preciso, evitando segundo guardado en rollback | Rechazos y discrepancia system/24h reproducidos;12 focal PASS, incluido recorrido local onboarding/reinicio |

Los bloques focales se solapan; no sumarlos como total. Ledger exacto de fuentes, patch-id y commits integrados: `artifacts/mobile259/integration/ledger.json`. Aplicación tras revisar ascendencia, equivalencia y paths; sin merge/cherry-pick. Favoritos conserva el contrato258: en Favoritos y liga, una vez por grupo y todos los partidos visibles.

## Pruebas y límites

**Suite Flutter completa:1643/1643PASS en113s, incluidos goldens. Analyze final limpio (ver analyze-final.log).** Tras dos ajustes exclusivos de estilo/sincronización de tests, las8regresiones raíz se ejecutaron de nuevo:8/8PASS. No se modificaron referenciasPNG. Logs en `artifacts/mobile259/`. Evidencia de agentes en sus worktrees `mobile-259-live`, `mobile-259-match` y `mobile-259-preferences`, subdirectorios `artifacts/mobile259-*`.

Limitaciones relevantes:

- Solo se rechaza detalle antiguo cuando ambos fetchedAt son válidos y distintos; timestamps ausentes/iguales/inválidos conservan reemplazo anterior. No se promete ordenar datos sin versión temporal.
- DELETE con solo PK mantiene semántica autoritativa porque no trae evidencia para ordenar; no se inventa revisión.
- El reset de perfil no resuelve duplicación real de entidades/fixtures o cobertura del proveedor. #222 requiere aún IDs/payload del caso real; no se fusiona por nombre.
- Los eventos canónicos del panel no inventan bridges de sustituciones o identidades ausentes.
- Pruebas locales no acreditan OAuth real, FCM real ni QA física. Ninguna fila del roadmap pasa a DONE final solo por mocks.

## Backlog y Android1.0

Los siete defectos locales quedan RESUELTO LOCAL en la matriz. Las funcionalidades existentes no se reimplementaron. #220 permanece candidato a cierre con evidencia física del nuevo artefacto. #217/#221/#147/#222 tienen correcciones/pruebas locales y dependencias concretas de datos reales. Epics de predicción de alineaciones, ranking editorial avanzado, Premium/noticias/proveedores se conservan como alcance posterior o backend, sin inventar datos ni convertirlos automáticamente enP0.

No se modifica el porcentaje de aceptación física del roadmap: continúa pendiente una candidata exacta, congelada y probada. El nuevo código cuenta con pruebas de regresión propias; la suite y CI del antiguo07a54b25 no se atribuyen al HEAD nuevo.

## Firma y Release Candidate

RC sigue **NO-GO**. Sin generar APK/AAB ni cambiar versionado. `1.0.0(5)` sigue propuesta sin aplicar. Paquete oficial objetivo `com.futbeat.futbeat`.

El procedimiento público de certificado CI continúa preparado en `codex/mobile-257-upload-fingerprint` @b35983e5, con workflow SHA2562e5361bcc820ed5e1ca2688d5bed4ca20aa26d08e43efdc1a9cffec37025f313. No se publicó ni ejecutó. No se accedió a secretos GitHub ni se modificó GooglePlay. Falta autorización específica para esa ejecución o evidencia pública directa del Upload Key Certificate de Play. No se genera otra clave.

Bloqueos reales de release:

1. Confirmar certificado de subida activo, configuración oficial y disponibilidad de versionCode5; aprobar congelación reproducible.
2. Publicar la consolidación móvil para CI Linux con autorización; no se ejecutó CI remoto de este HEAD.
3. Claude debe acreditar contrato pasivo desplegado y sus efectos secundarios para autorizar conexión; no se consultó producción.
4. Acreditar READY/aislamiento y probar físicamente el artefacto exacto. No se usó ADB, no se cambió QA123 ni datos del A32.

## Siguiente acción

Revisión de la consolidación y autorización de publicación para CI. En paralelo, resolver la comprobación pública del certificado upload con el diseño257 ya preparado. Tras ambas aprobaciones, congelar una únicaRC y validar su binario exacto. No crear una nuevaAPK solo para aumentar numeración ni repetir el inventario.

Logs finales: `artifacts/mobile259/flutter-full.log`, `root-final-tests.log`, `analyze-final.log`. Un intento de pruebas simultáneas en el mismo worktree encontró sqlite3.dll bloqueada por la suite; se repitió secuencialmente tras finalizarla y pasó. Se conserva evidencia de los fallos de fixture/infraestructura, sin contarlos como regresiones del producto.
