# NIGHT230 — dos casos golden de alineaciones

Base: 175e1b3. No se modificó código productivo ni ningún PNG de referencia.

## Causa acotada y demostrada

No es una nueva diferencia de MOBILE229: los seis renders obtenidos de nuevo en NIGHT230 tienen el mismo SHA-256 que los seis testImage conservados de MOBILE229. La extracción común de fuentes conserva exactamente orden, familia, assets y carga asíncrona anteriores; tampoco cambia esos renders.

Las tres referencias Match Center se actualizaron por última vez en a25250a (28 octubre), con altura de medio campo 480, fila92, avatar52 y separación foto/nombre6. La corrección física A32 75f60b8 (30 octubre) cambió medio campo a524, fila100, avatar46, separación3 y separación de eventos3→2. Las tres referencias polished son aún anteriores, e2f062c (27 octubre), con altura520/fila96/edge20; a25250a cambió luego edge12 sin refrescarlas.

Los tests usan viewport390×844 (y390×2320 en synthetic), DPR1; esos valores, los fixtures y los archivos Roboto no cambiaron. La comparación pixel a pixel Match Center top tiene cero píxeles distintos por encima de y382: encabezado, texto, marcador y pestañas son idénticos. Todos los cambios de esa captura están dentro del campo. En capturas desplazadas, los mismos desplazamientos fijos ahora muestran regiones distintas porque cambió la geometría del campo.

| Referencia | Píxeles distintos | Porcentaje |
|---|---:|---:|
| lineups_match_center_top | 25190 | 7,653% |
| lineups_match_center_home | 69978 | 21,260% |
| lineups_match_center_away | 165620 | 50,316% |
| lineups_polish_synthetic | 269916 | 29,832% |
| lineups_polish_home_viewport | 44255 | 13,445% |
| lineups_polish_away_viewport | 74224 | 22,550% |

No se atribuye este resultado a diferencias Windows/Linux. El historial y la ubicación de los cambios demuestran geometría esperada anterior, no un error nuevo de fuentes. Las diferencias de rasterización entre plataformas quedan fuera de esta comprobación.

## Regresión funcional adicional descubierta

Se añadió carga explícita de Roboto de la app en las pruebas no pixel de suplentes y en la fase A32 de pitch; antes usaban la fuente de prueba predeterminada. Se cubren escalas1.0,1.1,1.3 a1080×2400 físicos y DPR2.625, preservando nombres, dorsal e incidencias.

Resultado en la base: suplentes3/3 PASS. El caso `combined pitch identifies both teams and adapts at large text scale` reproduce un overflow real de5px a escala1.3 con Roboto (1.0/1.1 no fallan). Columna de _PitchPlayer: contenido105px dentro de fila100px. Fixture5-4-1 local y4-2-3-1 visitante; jugadorhome-2 tiene amarilla30 y salida75. Se conserva esta regresión FALLANDO para que el orquestador corrija el widget productivo en su frente UI; no se ocultó recortando contenido.

## Resultado de pruebas y referencias

Pruebas focales de layout: 13 PASS,1 FAIL (nueva cobertura escala1.3). Los dos casos golden siguen fallando con los seis mismos PNG históricos. No se usa una omisión ni tolerancia mayor para declararlos verdes.

El orquestador revisó visualmente las parejas master/actual y consideró intencional la geometría75f60b8. Sin embargo, la revisión automática de aprobación rechazó la ejecución de --update-goldens por riesgo de ocultar regresiones y falta de aprobación expresa del usuario. No se intentó eludir el rechazo mediante copias ni ejecución indirecta. Referencias intactas. Además, el nuevo overflow debe corregirse antes de una eventual actualización explícitamente autorizada.

Evidencias: artifacts/night230-goldens/diff-metrics.json y apps/mobile/test/failures/*_{masterImage,testImage,isolatedDiff,maskedDiff}.png. Son imágenes de widgets locales, no nuevas capturas físicas.
## Integración del orquestador

La regresión anterior ya pasa en night-mobile-230: se calcula el espacio real de nombres e incidencias con la fuente/escalado vigentes y se mantiene la misma altura en ambas mitades. No se recortan eventos ni se reduce la tipografía. Los casos densos de cinco incidencias en una fila de cinco jugadores pasan a escalas1.0 y1.3. Primer conjunto integrado:61PASS; conjunto posterior de densidad/media/marcadores/cronología:38PASS. Analyze sin incidencias.

Las seis referencias siguen intactas y la autorización explícita solicitada permanece pendiente. La corrección productiva del overflow no se condiciona a su actualización.