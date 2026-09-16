# Monetización de FutBeat

FutBeat se diseña con dos niveles comerciales desde el inicio, sin acoplar la monetización al motor deportivo.

## Free

La versión gratuita debe conservar la utilidad principal de FutBeat:

- marcadores y eventos en vivo;
- calendario, tablas, equipos, jugadores, noticias y fichajes según cobertura;
- seguimiento básico;
- notificaciones esenciales.

Se financiará principalmente con publicidad. Los anuncios no deben interrumpir un evento LIVE crítico, ocultar el marcador ni bloquear una notificación de gol. Los espacios publicitarios deben estar definidos por componentes propios de presentación para poder cambiar de red publicitaria sin tocar dominio, proveedores o almacenamiento.

## Premium

Premium debe ser un entitlement, no una aplicación distinta. Como mínimo podrá incluir:

- experiencia sin anuncios;
- mayor personalización de alertas;
- seguimiento ampliado;
- funciones estadísticas o de análisis avanzadas que realmente aporten valor;
- futuras ventajas de personalización/sincronización.

No se deben quitar de Free funciones esenciales de seguridad o exactitud de resultados para forzar la suscripción.

## Arquitectura

```text
Sports Providers -> FutBeat Data Engine -> API/Realtime -> Mobile
                                                   |
                                      Entitlements / Ads
```

El motor de datos produce la misma verdad deportiva para todos los usuarios. La capa de monetización decide presentación, límites de conveniencia y funciones Premium, pero nunca modifica marcador, eventos o procedencia.

Principios:

1. Nunca incluir claves de proveedores deportivos o redes publicitarias privadas en repositorios o respuestas públicas.
2. Mantener `Plan/Entitlement` desacoplado de Google Play Billing / App Store para poder probar y cambiar proveedores.
3. Centralizar ubicaciones de anuncios y aplicar frequency caps.
4. No mostrar interstitials al abrir una notificación de gol ni durante transiciones críticas del Match Center.
5. Medir ARPDAU, fill rate, eCPM, conversión a Premium y retención antes de aumentar presión publicitaria.
6. Revisar licencias de datos, escudos, fotografías y términos de cada proveedor antes del lanzamiento comercial.
