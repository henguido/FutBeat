# FutBeat · validación comercial Android

Base congelada `13919679cc49426f9a133db2edc3822dab1a9c7a`. Trabajo local en `codex/android-commercial-qa`.

| Área | Estado | Evidencia y dependencia |
|---|---|---|
| Anuncios | Implementado en cliente, configuración productiva pendiente | Banner adaptativo entre grupos del feed Partidos, hasta cinco espacios y ninguno en el filtro En vivo. Sin intersticiales, anuncios recompensados ni espacios dentro del Match Center. El slot desaparece ante error o cambio a Premium. |
| Consentimiento | Implementado en cliente, pendiente de aceptación | UMP comprueba consentimiento y expone «Opciones de privacidad» cuando corresponde. Errores dejan anuncios productivos bloqueados. La unidad de prueba omite UMP, por lo que un banner de prueba no acredita el flujo de consentimiento. |
| Premium y Billing | Parcial | Pantalla de ofertas y restauración, compra por Play y estados pendiente, cancelado y fallo. Los precios proceden de Play. No hay IDs aprobados para este ensayo. |
| Derechos | Parcial | Play local, producto permitido y etiqueta de cuenta. El acceso no se concede desde el callback de compra. Falta verificación de servidor del token, vínculo a cuenta y estado autoritativo de expiración o revocación. |
| Restauración y offline | Parcial | La restauración depende de lo que Play devuelva para la cuenta de tienda y de la coincidencia de la cuenta FutBeat. El caché local aplica un plazo de tres días y tres días adicionales de gracia. No hay sincronización autoritativa independiente entre dispositivos. |
| Push | Implementado en cliente, pendiente de aceptación | FCM, registro y preferencias existen. Flag separado apagado. |
| Facebook Login | Implementado en cliente, configuración pendiente | Proveedor OAuth y flag separado. Falta aceptación de configuración y retorno en el binario distribuido. |

La rama evita reconocer pagos pendientes y bloquea configurar productos Premium en release hasta tener verificación de servidor. Para terminar Premium, acordar con backend el contrato autenticado que verifique token, paquete, producto y cuenta, persista el derecho con caducidad y procese renovaciones y revocaciones. La confirmación de Play debe seguir a la verificación y concesión duradera. Incluir el tratamiento del derecho y sus datos en la aceptación de R05 con cuentas separadas autorizadas.

## APK de anuncios de prueba

Partir del JSON público aprobado de Internal Testing. Añadir `FUTBEAT_COMMERCIAL_QA=true` y `FUTBEAT_ADMOB_TEST_ADS=true`. Cambiar `FUTBEAT_ADS_DISABLED` y `FUTBEAT_OAUTH_GOOGLE_ENABLED` a `false`. Mantener R05 y acceso de sesión activos. Eliminar unidades reales y cualquier ID Premium. Pasar `FUTBEAT_COMMERCIAL_QA=true` también en el entorno y compilar con `flutter build apk --debug --dart-define-from-file=<json>`. El paquete aislado es `com.futbeat.futbeat.commercialqa`. Usa el App ID de muestra de Google. El callback aislado no está autorizado en Supabase. Para pruebas de cuenta usar una sesión QA aprobada mediante correo; evitar crear cuentas para un simple smoke de UI.

La APK sirve para comprobar un banner marcado como prueba, ocupación en el feed, comportamiento sin red y navegación. La aceptación de UMP requiere mensajes configurados en AdMob y un dispositivo de prueba autorizado. Antes de monetizar, revisar política de privacidad, ficha de seguridad de datos, declaración de anuncios, opciones de privacidad y declaraciones de compras y suscripciones. La prueba de Billing real requiere producto y plan de prueba aprobados, paquete y artefacto reconocidos por Play y un license tester con instrumentos de prueba. La variante de anuncios aislada deja Billing apagado.

Recomendación: publicar 1.0 con la candidata congelada y activar monetización en una actualización después de la aceptación física de Ads/UMP y de la verificación autoritativa de Premium.
