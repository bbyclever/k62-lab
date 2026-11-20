# Esferas minimalistas K62

Fondos OLED (negro real, píxeles apagados) para la **esfera personalizada** de FitCloudPro. El reloj dibuja la hora encima; elige en FitCloudPro el color blanco (ámbar para `6-ambar`).

| Carpeta | Úsala si tu K62 es… |
|---|---|
| `redonda-466/` | redondo AMOLED de 1,43" (lo más común) |
| `redonda-454/` | redondo, si el de 466 queda recortado |
| `rect-410x502/` | rectangular AMOLED |
| `rect-240x284/` | rectangular TFT de 1,83" o 1,85" |

## Aplicarla (iPhone)

1. Esta carpeta está en OneDrive. En el iPhone, abre la app OneDrive › `K62/k62-lab/windows-minimal/watchfaces/` › imagen › Compartir › **Guardar imagen**.
2. Enciende el Bluetooth y abre FitCloudPro. Si pide volver a vincular el K62, acéptalo y confírmalo en el reloj (el notebook pierde su sesión; volver a vincularlo luego es posible).
3. FitCloudPro › Dispositivo › **Esferas** › **Personalizada** › Fondo › elige la imagen; posición de la hora: centro; color: blanco › Sincronizar.

Regenerar o crear variantes: `.venv\Scripts\python.exe tools\make_faces.py`.
