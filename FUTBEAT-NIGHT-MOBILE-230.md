# FUTBEAT NIGHT MOBILE 230

Rama: codex/night-mobile-230. Base: 175e1b33e6ae29a53fbd74758ec929d45a75743b. Inicio verificable: 2026-10-31 07:14:53 UTC. Este informe registra trabajo ejecutado, no una promesa de ejecución desatendida de ocho horas.

## Correcciones integradas

- 2450201: una respuesta REST en vuelo ya no resucita una fila eliminada por Realtime; conserva un INSERT posterior legítimo.
- 2dad0bf: agrupa mantenimiento de disco de imágenes. Ensayo local: 18 descargas, 18→2 recorridos completos; misma tanda de mantenimiento 18→1. Límites/TTL no ampliados.
- 1a8eb89: una tabla explícitamente Clausura no se usa para un partido Apertura aunque falte stage; grupos genéricos siguen válidos.
- c5baf6c: fotografía verificada de un alias de proveedor reutiliza canonicalPlayerId y disco entre club y selección. Sin fusiones por nombre.
- 894b756: conserva cuatro marcadores estructurados del fixture real; un null explícito del detalle prevalece.
- 0caa36e: decodifica avatares al tamaño/densidad visible, con máximo1024. Ensayo codec512×512→60×60 para20dp@3x:1.048.576→14.400 bytes RGBA; no es una medición de RSS Android.
- 891b7dd: cronología compacta elimina solo metadatos redundantes comprobados; conserva VAR/anotaciones y añade fotos canónicas verificadas. Filas de campo miden fuente/escalado/eventos; regresión A32 con cinco incidencias pasa a escalas1.0 y1.3 sin recortar información.
- 45d5bc4: E2E pasivo local con eventos reales guardados:3GET,2sharedFlights,máximo2 simultáneas; reinicio de repositorio/SQLite,0 intentos HTTP;25eventos canónicos,22IDs de detalle,4marcadores. SQLite61.440bytes.

## Validaciones

- Focales integradas:61PASS. Conjunto posterior densidad/media/marcadores/cronología:38PASS; seis goldens de cronología sin modificar pasan.
- Analyze final:PASS,19,6s.
- Suite móvil final y APK: resultados pendientes de terminar; ver artifacts/night230.
- Cambio de día/reanudación revisado de forma acotada: comportamiento existente adecuado; no se añadió polling.

## Límites y siguiente coordinación

- Dos casos golden de alineación comparan seis referencias anteriores al cambio75f60b8. Referencias intactas. La revisión automática rechazó su actualización por riesgo de ocultar regresiones y exigencia de autorización expresa; se solicitó y permanece pendiente.
- Una retractación LIVE puede dejar una incidencia antigua en detalle: las22claves fallback canónicas y22IDs del detalle no comparten identidad. No se oculta por nombre/minuto. Ver docs/qa/NIGHT230-PASSIVE-CACHE-CONTRACT.md para contrato puntual requerido a Claude.
- El adaptador pasivo está probado localmente, NO activado en la app; no se afirma que rutas ordinarias no hidraten backend. Conectada+34 no debe instalarse sin autorización.
- No se consultó ni modificó producción, ni se ejecutaron migraciones, push, merge o llamadas GOAL. No se activó FCM.

## Checkpoint 07:49 UTC

Suite portable móvil completa (todos *_test.dart salvo visual_test.dart, convención previa): **1.405 PASS,2 FAIL**,4m56s. Fallan únicamente lineups_match_center_visual_test y lineups_visual_test; sin cambios de referencias ni tolerancias. AnalyzePASS. Nueva prueba pasiva incluida en esta suite.

APK conectada compilada desde45d5bc4:1.0.0+34,com.futbeat.futbeat.qa,111.109.080bytes,SHA256 EEFD44C3284B603181047C1FF6F6F5263B9CF4865911CAA48F1D5F086BEFBF39. DebugsignerSHA2566533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362. Tresbibliotecasarm64 comprobadas. DEMOfalse,OAuth/Push/adsdesactivados,diagnósticoQAactivo. ConfigsoloURLHTTPS+tokenpúblicoanon; no se imprimió ni publicóelvalor. **NOINSTALADA**.

10/10notificacionesbackendlocalesPASS:dry_run,transportefalso,corrección/dedup/terminal; sinFCMniSupabase. Revisiónpuntualdetectómensaje de error de cuenta potencialmente sensible en log; correcciónlocalenvalidación, no incluida todavía en el artefacto45d5bc4.

A32 aislado:sinredactiva; QA+33originalSHA02F2930721185B5BC5DC1E81502C58621323927A24BE20C3D0210ED4B0BCAF37; SQLiteantesc38f69df8b0723d4e18a363cb8d02d47f21e924a9cc7e11d493673e84a3efda4. RespaldoyguardiánindependientePID29720activos. Ningunaappabiertaaún.
