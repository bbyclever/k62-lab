# K62 Lab v0.1 (solo lectura)

Prototipo web para conectar un smartwatch **K62 / FitCloudPro** desde un **iPhone** por Bluetooth Low Energy con un navegador compatible con Web Bluetooth como Bluefy.

## Qué hace

- Selección y conexión manual al K62.
- Lecturas GATT de características previamente identificadas: FEC9, FEA1, FF04, FFD2 y FFF3.
- Suscripción a notificaciones de FEA1 (sin enviar comandos de firmware).
- Registro local y exportación JSON.

## Qué no hace

- No instala apps en el reloj.
- No cambia firmware, configuración ni esferas.
- No lee mensajes de WhatsApp desde iOS.
- No contiene funcionalidad para escribir comandos BLE ni ejecutar actualizaciones DFU.
- **No incluye el SDK nativo FitCloudKit**, que requiere una app iOS compilada y firmada para su ejecución.

## Publicar usando solo el iPhone

1. Instala Bluefy desde App Store Chile: https://apps.apple.com/cl/app/bluefy-web-ble-browser/id1492822055
2. Crea un repositorio de GitHub, por ejemplo `k62-lab`.
3. Sube `index.html` al nivel principal del repositorio mediante GitHub web (si la versión móvil no muestra `Add file`, usa `Solicitar sitio web de escritorio` en Safari).
4. En el repositorio: **Settings > Pages > Build and deployment > Deploy from a branch > main / (root)**.
5. Abre `https://TU-USUARIO.github.io/k62-lab/` dentro de **Bluefy** (NO en Safari normal).
6. Enciende el reloj, asegúrate de que otra aplicación no tenga una conexión exclusiva, pulsa **Conectar K62** y selecciónalo en el diálogo Bluetooth.
7. Pulsa **Leer valores**. Si quieres, activa **Escuchar** en FEA1. Usa **Exportar JSON** para compartir las respuestas.

## Notas de seguridad y privacidad

- Asegúrate de seleccionar tu propio K62.
- El navegador debe solicitar autorización para Bluetooth.
- Los datos quedan en memoria local de la página; solo se exportan si pulsas el botón.
- No pongas tokens, contraseñas, credenciales, datos clínicos, ni información privada en el repositorio público.
- GitHub Pages es un hospedaje HTTPS de archivos estáticos; la página no realiza llamadas de red para enviar los datos BLE.
- Las suscripciones GATT administran automáticamente el descriptor CCCD, pero el proyecto no incluye escrituras personalizadas ni DFU.
- Algunas características pueden rechazar las lecturas; el programa registra esos errores para continuar con el diagnóstico.
