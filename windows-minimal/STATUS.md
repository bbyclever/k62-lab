# K62 Minimal Control: estado

Última actualización: 19-11-2026 · Firmware del reloj: 9153.2370.104 (informa `1.04 (9153)`) · Windows 11 + Intel Wireless Bluetooth

## Protocolo

El K62 usa el protocolo FitCloudPro/TopStep descrito en la implementación abierta de Gadgetbridge (`fitcloud/ak102`): servicio `000001FF-…-D293`, `FF02` de escritura y `FF03` de notificaciones. La trama es `AB | flags | len | CRC-16/ARC | seq` + `[cmd][ver][key][len][data]`.

- El ID visible de FitCloudPro (`ft_…`) **no** sirve para el login: el reloj responde `NEED_BIND`.
- **Notebook vinculado al reloj** con aprobación expresa del propietario (19-11-2026). Los reconexiones posteriores dan login `OK` sin volver a vincular.

## Verificado en el reloj

| Función | Resultado |
|---|---|
| Conexión BLE y sesión desde Windows | ✅ Login OK, batería y firmware leídos |
| Pantalla de llamada entrante (cmd 4, key 1) | ✅ Aparece y se cierra (key 2) |
| Botones de música del reloj → Windows | ✅ Pausó y cambió de canción en el notebook; volumen ± también funciona |
| Notificación enviada desde Windows | ⚠️ Llega, pero desplazada (ver abajo) |
| Ocultar pantallas (PageConfig, ítem 23) | ❌ El reloj guarda el valor, pero la UI 7024 no lo aplica. **Se restauró el original** (`feff`) |

### Formato de notificación

El bloque de capacidades del reloj declara el formato largo (función 267), pero el firmware interpreta el **formato antiguo**: nombre de 20 bytes con relleno + longitud + texto. Con el formato largo, el texto aparecía desplazado 16 bytes («ribo para…»). Ahora se fuerza el formato antiguo (`force_legacy_notifications`). **Falta volver a medir** cuántos caracteres muestra el reloj con el formato correcto: la medida anterior de 60 no es válida, porque se hizo con el formato largo.

## Cambio visual drástico: esferas

- No hay vía validada para cambiar los menús o el launcher: están en el firmware y solo se pueden modificar flasheando por DFU, sin método de recuperación. **Descartado.**
- La esfera sí se puede personalizar con FitCloudPro. `tools/make_faces.py` genera 6 esferas OLED minimalistas para 4 resoluciones de K62, en `watchfaces/`; las instrucciones están en `watchfaces/LEEME.md`.
- Para aplicarla hay que volver a vincular FitCloudPro en el iPhone, y entonces el notebook pierde su sesión.

## Limitaciones reales

- **WhatsApp:** iOS no permite que accesorios ni Windows envíen respuestas. El reloj puede mandar el evento de respuesta rápida, pero no llega a WhatsApp.
- **Vinculación exclusiva:** el reloj se vincula a un solo usuario. O lo gestiona FitCloudPro en el iPhone (esferas y avisos), o el notebook (puente de notificaciones y música de Windows).
- **Puente del notebook:** reenviar notificaciones y controlar la música de Windows solo funciona con el notebook encendido y cerca.
- **Música y llamadas del iPhone:** usan el enlace Bluetooth clásico del reloj (HFP/AVRCP), sin pasar por el notebook.

## Vía principal ahora: app iOS propia (`../ios-minimal/`)

El fabricante publica su SDK oficial ([FitCloudPro-SDK-iOS](https://github.com/htangsmart/FitCloudPro-SDK-iOS)). Con él, la app K62 Minimal sustituye a FitCloudPro:

- vinculación + Bluetooth clásico (llamadas y música) en un paso;
- apps que avisan en el reloj;
- **esferas DIY instaladas en el reloj** (FitCloudWFKit + OTA/DFU oficial);
- **complemento WhatsApp** para leer y responder desde el reloj, si el firmware declara `supportsWhatsApp`.

Estado (19-11-2026): **compila en GitHub Actions** (run 44647361717, artefacto `K62Minimal-unsigned-ipa`, 10,9 MB). **Aún sin instalar ni probar en el reloj.** Se instala firmando el IPA con tu propio Apple ID.

## Próxima tarea concreta

1. Aplicar una esfera de `watchfaces/` con FitCloudPro.
2. Si se vuelve a usar el puente: medir el límite visible de texto con el formato antiguo y ajustar `page_bytes`.
