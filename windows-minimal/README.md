# K62 Minimal Control (Windows)

Centro de control local para el smartwatch K62 (protocolo FitCloudPro), por BLE desde el notebook.

```powershell
cd k62-lab\windows-minimal
.\run.ps1                                   # crea .venv la primera vez y abre http://127.0.0.1:8762
.\.venv\Scripts\python.exe k62_cli.py probe # verificación rápida: conectar + login
```

Si PowerShell bloquea `run.ps1`, ejecuta `.\.venv\Scripts\python.exe k62_minimal.py`.

| Archivo | Función |
|---|---|
| `k62min/protocol.py` | Trama, CRC-16/ARC, comandos FitCloud y paginación |
| `k62min/link.py` | Conexión BLE (Bleak), ACK, login y comandos del reloj |
| `k62min/winbridge.py` | Notificaciones de Windows (Enlace Móvil) y control multimedia |
| `k62min/server.py` + `static/index.html` | App local con interfaz oscura |
| `local/settings.json` | ID de sesión y preferencias (ignorado por git) |

Seguridad: no hay rutas DFU/OTA, de escritura arbitraria ni de fuzzing. `bind` solo se ejecuta si lo confirmas en la interfaz (escribiendo «VINCULAR») y en el reloj.

Estado y limitaciones: [STATUS.md](STATUS.md).
