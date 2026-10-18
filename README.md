# takeit

Transferencia de archivos **peer-to-peer** con cifrado de extremo a extremo, escrita en [raylang](https://github.com/ray-language/raylang).

**Versión actual: `0.4.0` (protocolo v5).** Un equipo envía archivos o carpetas; el otro recibe. No hay cuenta, no hay servidor en la nube, no hay intermediario que vea el contenido: solo TCP, una contraseña de un solo uso, un PAKE (CPace) y AEAD (ChaCha20-Poly1305).

```text
# Emisor
$ takeit send ./informe.pdf
Password: 7k9m-qp2x-lw4n-ab01
Waiting on 0.0.0.0:7421 …
Receiver should run: takeit recv --host <this-ip> --port 7421 --password 7k9m-qp2x-lw4n-ab01

# Receptor (otra máquina / otra terminal)
$ takeit recv --host 203.0.113.10 --port 7421 --password 7k9m-qp2x-lw4n-ab01
Saved: ./informe.pdf (1.2 MiB)
```

Varios archivos y carpetas en una sola sesión (las carpetas van enteras, bajo su nombre):

```text
$ takeit send ./fotos ./informe.pdf
…
(205 files, 300.7 MiB)

$ takeit recv --host 203.0.113.10 --port 7421 --password … --out ./inbox
Saved: 205 files in ./inbox/ (300.7 MiB)
```

Comparte la contraseña por un canal aparte (chat, voz, SMS). Quien no la tenga no puede abrir los chunks.

## Estado actual

| Capacidad | Estado |
|-----------|--------|
| `send` / `recv` de **uno o más archivos y carpetas** por sesión | ✅ listo |
| Cifrado E2E (ChaCha20-Poly1305) + auth por contraseña con PAKE (CPace): sin ataques offline | ✅ listo |
| Streaming (chunks 256 KiB, sin cargar el archivo en RAM) | ✅ listo |
| Hash de integridad SHA-256 (incremental, M126) + ACK final | ✅ listo |
| Barra de progreso en stderr (`sending` / `receiving`) | ✅ listo |
| Timeouts de idle en accept/lectura (`--timeout`, default 120 s) | ✅ listo |
| Puerto libre automático (`--port 0` / omitido en send) | ✅ listo |
| Binarios nativos (Linux, macOS, Windows; x86_64 y ARM64) + `install.sh` / `install.ps1` + CI de releases | ✅ listo |
| Tests (`roundtrip_test`, `chunk_review_test`) | ✅ listo |
| Reanudación de una transferencia cortada, por archivo (solo se envía lo que falta) | ✅ listo |
| Manifiesto cifrado, rutas confinadas al directorio de salida | ✅ listo |
| Relay / códigos cortos / NAT traversal | ⏳ pendiente |
| TLS en el transporte | ⏳ opcional a futuro |

Alcance de red hoy: **P2P directo**. Emisor y receptor deben poder alcanzarse por TCP (misma LAN, IP pública, o túnel).

Detalle del protocolo y roadmap: [`docs/PLAN.md`](docs/PLAN.md).

## Por qué takeit

- **E2E de verdad** — la clave de sesión sale de un PAKE (CPace) sobre la contraseña: quien escuche la red no puede ni descifrar ni probar contraseñas offline; el contenido viaja cifrado con ChaCha20-Poly1305.
- **Streaming** — el archivo no se carga entero en RAM; se lee y escribe por trozos (256 KiB) con hash de integridad SHA-256 (incremental).
- **UX mínima** — genera la contraseña, escucha, muestra el comando exacto del receptor y una barra de progreso en stderr.
- **Un solo binario** — sin runtime, sin deps externas; compilado a código nativo con `ray build --native`.
- **Escrito en Raylang** — crypto, red y CLI sobre la stdlib del lenguaje.

## Instalación rápida

```sh
curl -sSfL https://raw.githubusercontent.com/ray-language/takeit/master/install.sh | sh
```

El script detecta tu OS/arquitectura, descarga el asset de la [última Release](https://github.com/ray-language/takeit/releases/latest) y lo deja en `~/.local/bin/takeit`.

| Variable | Descripción | Default |
|----------|-------------|---------|
| `TAKEIT_VERSION` | Tag concreto (`v0.2.0`) | última release |
| `TAKEIT_BIN_DIR` | Directorio de instalación | `$HOME/.local/bin` |
| `TAKEIT_REPO` | `owner/repo` | `ray-language/takeit` |
| `TAKEIT_DRY_RUN` | Solo imprime el plan | (vacío) |

Ejemplo:

```sh
TAKEIT_VERSION=v0.2.0 curl -sSfL https://raw.githubusercontent.com/ray-language/takeit/master/install.sh | sh
```

### Windows

En PowerShell (Windows PowerShell 5.1 o PowerShell 7):

```powershell
irm https://raw.githubusercontent.com/ray-language/takeit/master/install.ps1 | iex
```

Detecta x86_64 o ARM64 (la del sistema, también desde un PowerShell emulado), descarga
`takeit-<target>.zip` de la [última Release](https://github.com/ray-language/takeit/releases/latest),
verifica su `.sha256`, deja `takeit.exe` en `%LOCALAPPDATA%\Programs\takeit` y añade esa carpeta
al `PATH` del usuario (las terminales nuevas lo ven; la actual ya lo tiene). Después se usa igual
desde PowerShell o `cmd`. Acepta las mismas variables que `install.sh` (`TAKEIT_VERSION`,
`TAKEIT_BIN_DIR`, `TAKEIT_REPO`, `TAKEIT_DRY_RUN`) y `TAKEIT_NO_PATH` para no tocar el `PATH`:

```powershell
$env:TAKEIT_VERSION = 'v0.4.0'; irm https://raw.githubusercontent.com/ray-language/takeit/master/install.ps1 | iex
```

A mano: descomprime el `.zip` de la Release en una carpeta del `PATH`.

- **Firewall**: quien ejecuta `takeit send` escucha conexiones. La primera vez, Windows pregunta si
  permite el acceso a `takeit.exe`; sin ese permiso el receptor se queda en `connect timeout`.
  (`takeit recv` solo se conecta hacia fuera y no lo necesita.)
- **Nombres**: un emisor Linux/macOS puede enviar nombres que Windows no admite (`a:b.txt`,
  `what?.txt`, `CON`, acabados en punto…) o que solo difieren en mayúsculas (`A.txt` y `a.txt`).
  El receptor en Windows rechaza el lote **antes de escribir nada**, con un error que dice qué
  nombre falla. (La colisión por mayúsculas se comprueba también en macOS.)

### Compilar desde el fuente

Necesitas el toolchain [raylang](https://github.com/ray-language/raylang) en el `PATH`:

```sh
git clone https://github.com/ray-language/takeit.git
cd takeit
ray build --native -o takeit --release
install -m 0755 takeit ~/.local/bin/takeit
```

Tests:

```sh
ray test
```

## Uso

```text
takeit send <file|dir>... [--bind HOST] [--port N] [--timeout SECS]
takeit recv --host HOST --port N --password PASS [--out PATH] [--timeout SECS] [--fresh]
```

| Flag | Quién | Qué hace |
|------|-------|----------|
| `--bind` | send | Dirección de escucha (default `0.0.0.0`) |
| `--port` | send / recv | Puerto (en send, omitido o `0` = el SO elige uno libre) |
| `--host` | recv | IP o hostname del emisor |
| `--password` | recv | Contraseña mostrada por el emisor |
| `--out` | recv | Directorio de destino (default: el actual; se crea si falta). Con un solo archivo puede ser el archivo destino |
| `--timeout` | ambos | Segundos de idle en accept/lectura; `0` = sin límite (default `120`) |
| `--fresh` | recv | Ignora los parciales de una transferencia cortada y empieza de cero |

Durante la transferencia, stderr muestra progreso (`sending` / `receiving` con %, velocidad y ETA).

### Reanudar

Si la transferencia se corta, el receptor conserva un `<archivo>.takeit.partial` por cada archivo
empezado (los ya completos también). Basta con volver a enviar lo mismo (`takeit send`,
contraseña nueva) y repetir `takeit recv` con el mismo `--out`: el emisor comprueba que cada
parcial es un prefijo de su archivo (SHA-256) y envía solo lo que falta; el que no lo es, se
reenvía entero. Ningún archivo aparece en su sitio hasta que el lote completo se verifica.

```text
$ takeit recv --host 203.0.113.10 --port 7421 --password …
resuming at 88.7 MiB
Saved: ./informe.pdf (300.0 MiB, resumed at 88.7 MiB)
```

## Seguridad (resumen)

1. Contraseña de 8 bytes CSPRNG, mostrada como `xxxx-xxxx-xxxx-xxxx`.
2. Handshake **CPace** (CPACE-X25519-SHA512, borrador CFRG) sobre la contraseña, con confirmación de clave en ambos sentidos: lo que viaja por el cable no permite probar contraseñas offline, un atacante activo tiene un solo intento por sesión, y cada sesión tiene claves nuevas (secreto hacia adelante).
3. Clave de sesión: HKDF-SHA256 del ISK de CPace → 32 B. El hello forma parte de la transcripción: alterarlo en tránsito hace fallar la autenticación.
4. Chunks AEAD; un fallo de autenticación aborta (contraseña mala o manipulación).
5. El hello en claro no lleva nombres: el manifiesto (rutas y tamaños) va cifrado. Magic `TAKE`, versión de protocolo `5`.
6. SHA-256 de cada archivo completo (hasher incremental de raylang, M126, también al reanudar) y de la sesión.
7. El receptor rechaza rutas absolutas, con `..` o que resuelvan fuera de `--out` (enlaces simbólicos incluidos).
8. Emisor y receptor cifran con la misma clave, cada uno en su propio espacio de nonces (tag de dirección).

Protocolo completo: [`docs/PROTOCOL_V5.md`](docs/PROTOCOL_V5.md). Un takeit 0.2/0.3 (v4) y un 0.4 no se entienden: el más antiguo pide actualizar.

## Arquitectura

```text
src/
├── main.ray          # CLI: send | recv
├── password.ray      # generar / normalizar contraseña
├── cpace.ray         # PAKE CPace (X25519 + Elligator2), con los vectores del borrador
├── framing.ray       # frames u32 BE + buffer de sobrante
├── protocol.ray      # hello, manifiesto, resume/start, frames AEAD, blobs
├── paths.ray         # validación de rutas del manifiesto
├── sources.ray       # expansión de archivos/carpetas del emisor
├── send.ray / recv.ray
├── progress.ray      # barra de progreso + map de errores I/O
├── streamhash.ray    # SHA-256 incremental para streaming (M126) + prefijo
└── fileread.ray      # lectura por trozos y rangos (seek para reanudar)
```

## Releases

Al publicar un tag `vX.Y.Z` (con la misma versión que `ray.toml`), GitHub Actions compila binarios nativos para:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `x86_64-apple-darwin`
- `aarch64-apple-darwin`
- `x86_64-pc-windows-msvc`
- `aarch64-pc-windows-msvc`

y los sube a la Release del tag como `takeit-<target>.tar.gz` (`.zip` en Windows) + `.sha256`.

```sh
# Ejemplo de corte de versión
# 1. Bump version en ray.toml → 0.4.0
# 2. Commit y:
git tag v0.4.0
git push origin v0.4.0
```

## Licencia

Proyecto de laboratorio Rayala / ray-apps. Ver el repositorio para términos.
