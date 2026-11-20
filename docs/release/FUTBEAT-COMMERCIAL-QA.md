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

## Aceptación comercial pendiente

En el Galaxy A32, la APK comercial 1.0.0 (16) ya instalada mostró «Anuncio de prueba» junto a los partidos después de reconectar y volver a primer plano. El feed conservó partidos sin red tras reiniciar el proceso. También abrieron Match Center y Favoritos. Estas pruebas corresponden a la APK de anuncios de muestra sin UMP. El fallo de carga y el tiempo de espera de AdMob se prueban localmente con el adaptador simulado. Android registró un percentil 95 de 105 ms en 144 cuadros de la APK debug. Hace falta una comparación en modo profile con y sin anuncios y un conteo de solicitudes por recorrido para acreditar rendimiento.

Para probar UMP físicamente, se necesita un registro Android aprobado en AdMob para el paquete aislado, su App ID autorizado y un mensaje aplicable publicado en Privacidad y mensajes. Para compilar la variante de aceptación, añadir FUTBEAT_COMMERCIAL_UMP=true al JSON comercial y pasar el App ID autorizado en la variable de entorno FUTBEAT_COMMERCIAL_UMP_APP_ID. El banner sigue usando la unidad de muestra de Google. Registrar únicamente el Galaxy de prueba si se requiere probar otra región mediante las opciones oficiales de depuración de UMP. Comprobar el primer formulario, la entrada de opciones de privacidad cuando UMP la exige, el reinicio sin borrar datos y el arranque sin red seguido de reanudación. Confirmar que al abrir las opciones se suspende el banner y que al cerrarlas se aplica la decisión actual de UMP.

Para Billing se requiere un paquete registrado en Play que coincida con el APK de pruebas, un producto y plan base aprobados, y una cuenta registrada como probador de licencias con métodos de prueba. Si se mantiene el aislamiento en el Galaxy, usar un registro separado para el paquete comercial o un dispositivo/perfil dedicado al paquete de Play. La prueba de derechos exige también un servicio de verificación en un entorno autorizado para compras de prueba. Probar reinicio, restauración y cambio de cuenta, además de expiración o revocación y ausencia de anuncios con el derecho vigente.

Recomendación: mantener la candidata congelada y activar monetización después de la aceptación física de Ads y UMP y de la verificación autoritativa de Premium.
