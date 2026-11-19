# K62 Lab Native (SwiftUI + Core Bluetooth)

Versión inicial experimental: **solo lectura**. No escribe características GATT, no utiliza DFU, no modifica el reloj y no envía datos a servidores.

## Objetivo

Investigar una alternativa a Bluefy cuando FitCloudPro ya tiene vinculado el K62. Esta aplicación nativa utiliza Core Bluetooth para:

1. Recuperar periféricos **que ya están conectados a iOS** y publican uno de los servicios GATT conocidos.
2. Recuperar periféricos previamente conocidos mediante **su identificador UUID de iOS**, introducido manualmente por quien realiza la prueba.
3. Escanear dispositivos anunciados como K62, como opción adicional.
4. Intentar una conexión GATT propia, descubrir el servicio FEE7 y leer **FEC9**, sin escrituras.

**Importante:** recuperar un objeto CBPeripheral no equivale a obtener permiso para conectarse o leerlo. Core Bluetooth puede recibir errores. No se ha probado con este dispositivo; no garantiza convivencia con FitCloudPro.

El UUID observado por Bluefy *podría no coincidir* con el identificador que entregue otra aplicación Core Bluetooth; no se incluye ningún identificador personal en el código.

## Compilación con iPhone solamente

En GitHub → pestaña Actions → workflow **K62 Lab Native - compile without signing** → **Run workflow**. Se ejecuta en un Mac temporal de GitHub con Xcode y compila para el **simulador iOS**, sin necesidad de certificado.

El workflow ahora compila dos productos: un build para **iOS Simulator** y un paquete **K62LabNative-unsigned.ipa** para iPhone real, adjunto como artefacto de GitHub Actions. El IPA **no está firmado**: no se instala simplemente pulsándolo desde Archivos. Debes firmarlo para tu dispositivo con una herramienta compatible antes de instalarlo.

### Opción experimental desde iPhone con iOS 27

[SideInstaller](https://sideinstaller.net/) es un proyecto independiente y abierto que declara permitir instalar SideStore o un IPA propio directamente desde iOS 27, sin Mac ni PC. Requiere una configuración inicial (LocalDevVPN, emparejamiento local y firma con una cuenta de Apple); **no se ha probado para este proyecto**. Consulta la documentación oficial y verifica el origen antes de introducir credenciales. Lo habitual en una cuenta gratuita es volver a firmar la aplicación cada siete días. Evita herramientas de certificados empresariales desconocidos.

Pasos previstos: (1) Ejecutar el workflow manual; (2) descargar el artefacto comprimido `K62LabNative-unsigned-ipa` desde GitHub Actions en Safari; (3) descomprimirlo en Archivos para obtener `K62LabNative-unsigned.ipa`; (4) importarlo en un firmador/instalador de confianza que permita IPA personalizado; (5) firmarlo e instalarlo; (6) conceder permiso Bluetooth al abrirlo. Este recorrido **depende de compatibilidad del instalador y de la versión de iOS**.

**Importante:** TestFlight requiere Apple Developer Program y un flujo de distribución adicional; no está habilitado en el proyecto.

No introducir claves, certificados privados ni contraseñas en el código público. Para una futura distribución se configurarán secretos de GitHub Actions y se revisarán los permisos y la firma.

## Próximas etapas

- Verificar que compile; después, preparar firma de desarrollo/distribución.
- Realizar una prueba real de recuperación de periféricos conectados.
- Integrar **FitCloudKit**, si sus condiciones y artefactos permiten incorporar el framework correctamente, y ejecutar su proceso documentado de vinculación/inicialización.
- Consultar configuración y capacidades antes de cualquier escritura persistente.

Documentación: [Apple Core Bluetooth](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager), [FitCloudPro SDK iOS](https://github.com/htangsmart/FitCloudPro-SDK-iOS).
