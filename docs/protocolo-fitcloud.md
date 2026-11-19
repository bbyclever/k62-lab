# K62 Lab — Bitácora del protocolo FitCloud (19-11-2026)

Este documento distingue **resultados comprobados en el K62**, **comportamiento documentado de SDKs para dispositivos FitCloud** y **funciones aún no demostradas**.

## Equipo de prueba

- Reloj anunciado como: `K62`.
- Aplicación de fábrica: FitCloudPro.
- Versión informada por la aplicación: `9153.2370.104`.
- Versión de interfaz mostrada en el reloj: `7024-01`.
- Laboratorio: Bluefy en iPhone, Web Bluetooth y GitHub Pages.
- **Privacidad:** no se publican aquí dirección Bluetooth/MAC, datos de salud, ni archivos JSON de sesiones.

## Confirmado en este dispositivo

1. Bluefy solicita y abre una conexión GATT mediante Web Bluetooth.
2. Se detectaron los servicios `000001ff-3c17-d293-8e48-14fe2e4da212`, `0000d0ff-3c17-d293-8e48-14fe2e4da212`, `00006287-3c17-d293-8e48-14fe2e4da212`, `fee7`, y un segundo `000001ff` con base distinta.
3. Las características `FEC9`, `FEA1`, `FF04`, `FFD2` y `FFF3` respondieron a lecturas sin necesidad de ejecutar la inicialización del SDK.
4. La suscripción de `FEA1` acepta `startNotifications()` y se recibieron eventos `characteristicvaluechanged`. La carga útil observada se repitió; su interpretación exacta sigue sin validarse.
5. `FF03` admite suscripción, pero ninguna de las pruebas pasivas produjo datos en ese canal.
6. El reloj siguió conectado durante la manipulación local de cronómetro y notificaciones. No se demostró que esas acciones envíen un comando remoto.
7. Las UUID `D0FF` y `6287` coinciden con perfiles usados por RealSil/Realtek para DFU. **Eso no identifica por sí solo el modelo del SoC ni autoriza flashear firmware.**

## Lo documentado por Hetang Smart para FitCloudKit iOS

La [guía oficial](https://github.com/htangsmart/FitCloudPro-SDK-iOS/blob/master/FitCloudKit/README_EN.md) propone este flujo de alto nivel:

1. Inicializar `FitCloudKit` con `FitCloudOption` y callbacks.
2. Usar `scanPeripherals` y observar los eventos de descubrimiento.
3. Conectar con `[FitCloudKit connect:peripheral]`.
4. Vincular con `bindUserObject:abortIfExist:block:`, observando eventos de vinculación.
5. Esperar los eventos `FITCLOUDEVENT_GETALLCONFIG_*` y `FITCLOUDEVENT_INITIALIZE_RESULT_NOTIFY` antes de confiar en la configuración.
6. Consultar `[FitCloudKit allConfig]` para capacidades declaradas por el firmware.
7. Consultar `getMessageNotificationSettingWithBlock:` si corresponde, después de la inicialización, para configuración de avisos.

Estos nombres son APIs nativas de `FitCloudKit`, **no** comandos GATT ni bytes listos para escribir en `FF02`. FitCloudKit se distribuye como framework nativo `.xcframework`, por lo que **no puede importarse directamente en HTML/JavaScript o Bluefy**.

## Qué se puede intentar después, con seguridad

- **En K62 Lab web:** seguir capturando los canales de notificaciones sin modificar ajustes; incluir marcas de tiempo por acción y comparar sesiones independientes.
- **En una aplicación iOS nativa con compilación y firma:** integrar el SDK oficial, vincular el reloj y consultar `allConfig()` y la configuración de avisos. Esto puede requerir un servicio de compilación macOS y mecanismos de firma/distribución de Apple; **un iPhone por sí solo no ejecuta Xcode**.
- **Para identificar paquetes binarios:** sería necesario obtener una traza autorizada de la comunicación de la propia app o una implementación abierta específica del mismo protocolo; no es seguro copiar comandos de otro reloj que solo comparta UUID.
- **Antes de cualquier modificación persistente:** identificar el modelo real del SoC y disponer de una vía de recuperación del firmware. No activar DFU ni enviar escrituras de prueba.

## Limitaciones concretas

- No se ha demostrado capacidad de instalar aplicaciones, cambiar el sistema operativo, quitar aplicaciones del reloj ni responder libremente WhatsApp desde iOS.
- Que Gadgetbridge admita características de ciertos FitCloud no garantiza que el K62 implemente todas.
- La documentación SDK describe funciones de alto nivel, pero no proporciona por sí sola los bytes de inicialización para Web Bluetooth.
- Las funciones de notificaciones del iPhone exigen permisos y comportamiento del sistema que una web abierta en Bluefy no puede sustituir.

## Referencias

- [FitCloudPro SDK iOS: guía de desarrollo](https://github.com/htangsmart/FitCloudPro-SDK-iOS/blob/master/FitCloudKit/README_EN.md)
- [FitCloudPro SDK iOS: repositorio](https://github.com/htangsmart/FitCloudPro-SDK-iOS)
- [Gadgetbridge: compatibilidad FitCloud](https://gadgetbridge.org/gadgets/wearables/fitcloud/)
- [OpenWearOTA: familias de protocolos DFU](https://github.com/HackSucks/OpenWearOTA/blob/main/DOCUMENTATION.md)

## Estado del proyecto

- [x] Descubrimiento GATT.
- [x] Conexión real desde iPhone y lectura de cinco características.
- [x] Suscripción en `FEA1`; `FF03` monitorizado.
- [x] Prueba con marcadores manuales y exportación JSON.
- [x] Desactivar lectura manual de `FF03` en K62 Lab v0.5.
- [ ] Confirmar modelo del chip y capacidades de firmware.
- [ ] Obtener y validar inicialización FitCloudKit en una app nativa.
- [ ] Ensayar una operación de configuración reversible y **documentada**, tras confirmar compatibilidad.
