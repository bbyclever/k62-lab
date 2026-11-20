# K62 Minimal (iOS)

Una app propia para el iPhone que **sustituye a FitCloudPro**. Usa el SDK oficial del fabricante ([htangsmart/FitCloudPro-SDK-iOS](https://github.com/htangsmart/FitCloudPro-SDK-iOS)), funciona sin el notebook y se instala con firma propia.

| Pestaña | Qué hace | API oficial |
|---|---|---|
| Reloj | Busca el K62, lo vincula y empareja el Bluetooth clásico (llamadas y música) en un paso. Muestra lo que permite el firmware | `connectAndBind(… withClassicBT: true)`, `allConfig` |
| Esfera | Crea una esfera con fondo y hora propios, la instala, cambia o borra esferas. Incluye 6 diseños OLED minimalistas | `FitCloudWFKit.create`, `sendNewOTA` / `FitCloudDFUKit` |
| Avisos | Elige qué apps vibran en el reloj; incluye el ajuste «Solo lo esencial» | `setEnabledNotificationApps` |
| WhatsApp | Si el firmware lo declara, prepara el complemento oficial para leer y responder desde el reloj | `FitCloudWhatsApp` |

## Compilar (sin Mac)

1. Sube el repositorio a GitHub.
2. En **Actions › K62 Minimal iOS - build unsigned IPA › Run workflow**, se compila en un Mac de GitHub.
3. Descarga el artefacto `K62Minimal-unsigned-ipa`.
4. Fírmalo con tu Apple ID (por ejemplo, SideStore o Sideloadly) e instálalo.

## Riesgos asumidos por el propietario

- Al vincular, FitCloudPro deja de tener sesión con el reloj.
- Instalar una esfera usa el modo de actualización del reloj. Una plantilla que no corresponda al modelo puede dejar la esfera o el reloj inservibles.
- Para la plantilla DIY, la app consulta el servidor de esferas documentado por el fabricante (`/public/dial/custom`). Si no hay acceso, se puede importar un `.bin` desde Archivos.

## Pendiente de verificar en el reloj

Nada de esto se ha probado todavía en el K62, porque falta compilar e instalar. Lo primero que hay que mirar es la pestaña Reloj › «Lo que este firmware permite».
