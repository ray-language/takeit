# takeit

Transferencia de archivos **peer-to-peer** con cifrado de extremo a extremo, escrita en [raylang](https://github.com/roberto-ayala/raylang).

**Versión actual: `0.1.0` (protocolo v2).** Un equipo envía un archivo; el otro recibe. No hay cuenta, no hay servidor en la nube, no hay intermediario que vea el contenido: solo TCP, una contraseña de un solo uso y AEAD (ChaCha20-Poly1305).

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

Comparte la contraseña por un canal aparte (chat, voz, SMS). Quien no la tenga no puede abrir los chunks.

## Estado actual

| Capacidad | Estado |
|-----------|--------|
| `send` / `recv` de **un archivo** por sesión | ✅ listo |
| Cifrado E2E (ChaCha20-Poly1305) + auth por contraseña | ✅ listo |
| Streaming (chunks 256 KiB, sin cargar el archivo en RAM) | ✅ listo |
| Hash de integridad SHA-256 (incremental, M126) + ACK final | ✅ listo |
| Barra de progreso en stderr (`sending` / `receiving`) | ✅ listo |
| Timeouts de idle en accept/lectura (`--timeout`, default 120 s) | ✅ listo |
| Puerto libre automático (`--port 0` / omitido en send) | ✅ listo |
| Binarios nativos + `install.sh` + CI de releases | ✅ listo |
| Tests (`roundtrip_test`, `chunk_review_test`) | ✅ listo |
| Multi-archivo (protocolo v3) | 📋 diseñado — [`docs/PROTOCOL_V3.md`](docs/PROTOCOL_V3.md) |
| Reanudación de transferencia a medias | ⏳ API en `fileread`; aún no cableada al protocolo |
| Relay / códigos cortos / NAT traversal | ⏳ pendiente |
| TLS en el transporte | ⏳ opcional a futuro |

Alcance de red hoy: **P2P directo**. Emisor y receptor deben poder alcanzarse por TCP (misma LAN, IP pública, o túnel).

Detalle del protocolo y roadmap: [`docs/PLAN.md`](docs/PLAN.md).

## Por qué takeit

- **E2E de verdad** — la clave se deriva de la contraseña + un salt público; el contenido viaja cifrado con ChaCha20-Poly1305.
- **Streaming** — el archivo no se carga entero en RAM; se lee y escribe por trozos (256 KiB) con hash de integridad SHA-256 (incremental).
- **UX mínima** — genera la contraseña, escucha, muestra el comando exacto del receptor y una barra de progreso en stderr.
- **Un solo binario** — sin runtime, sin deps externas; compilado a código nativo con `ray build --native`.
- **Escrito en Raylang** — crypto, red y CLI sobre la stdlib del lenguaje.

## Instalación rápida

```sh
curl -sSfL https://raw.githubusercontent.com/roberto-ayala/takeit/main/install.sh | sh
```

El script detecta tu OS/arquitectura, descarga el asset de la [última Release](https://github.com/roberto-ayala/takeit/releases/latest) y lo deja en `~/.local/bin/takeit`.

| Variable | Descripción | Default |
|----------|-------------|---------|
| `TAKEIT_VERSION` | Tag concreto (`v0.1.0`) | última release |
| `TAKEIT_BIN_DIR` | Directorio de instalación | `$HOME/.local/bin` |
| `TAKEIT_REPO` | `owner/repo` | `roberto-ayala/takeit` |
| `TAKEIT_DRY_RUN` | Solo imprime el plan | (vacío) |

Ejemplo:

```sh
TAKEIT_VERSION=v0.1.0 curl -sSfL https://raw.githubusercontent.com/roberto-ayala/takeit/main/install.sh | sh
```

### Compilar desde el fuente

Necesitas el toolchain [raylang](https://github.com/roberto-ayala/raylang) en el `PATH`:

```sh
git clone https://github.com/roberto-ayala/takeit.git
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
takeit send <file> [--bind HOST] [--port N] [--timeout SECS]
takeit recv --host HOST --port N --password PASS [--out PATH] [--timeout SECS]
```

| Flag | Quién | Qué hace |
|------|-------|----------|
| `--bind` | send | Dirección de escucha (default `0.0.0.0`) |
| `--port` | send / recv | Puerto (en send, omitido o `0` = el SO elige uno libre) |
| `--host` | recv | IP o hostname del emisor |
| `--password` | recv | Contraseña mostrada por el emisor |
| `--out` | recv | Ruta de destino (default: nombre del archivo) |
| `--timeout` | ambos | Segundos de idle en accept/lectura; `0` = sin límite (default `120`) |

Durante la transferencia, stderr muestra progreso (`sending` / `receiving` con %, velocidad y ETA).

## Seguridad (resumen)

1. Contraseña de 8 bytes CSPRNG, mostrada como `xxxx-xxxx-xxxx-xxxx`.
2. Salt de 16 B en el handshake en claro.
3. KDF: `hmac_sha256(sha256(password), salt ‖ "takeit-v1")` → clave de 32 B.
4. Chunks AEAD; un fallo de autenticación aborta (contraseña mala o manipulación).
5. Un solo archivo por sesión; magic `TAKE`, versión de protocolo `2`. El hash de integridad es el SHA-256 real del texto plano (hasher incremental de raylang, M126).

## Arquitectura

```text
src/
├── main.ray          # CLI: send | recv
├── password.ray      # generar / normalizar contraseña
├── kdf.ray           # password + salt → key 32 B
├── framing.ray       # frames u32 BE + buffer de sobrante
├── protocol.ray      # hello, auth, chunks AEAD, done
├── send.ray / recv.ray
├── progress.ray      # barra de progreso + map de errores I/O
├── streamhash.ray    # SHA-256 incremental para streaming (M126)
└── fileread.ray      # lectura por trozos (incluye seek para resume futuro)
```

## Releases

Al publicar un tag `vX.Y.Z` (con la misma versión que `ray.toml`), GitHub Actions compila binarios nativos para:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `x86_64-apple-darwin`
- `aarch64-apple-darwin`

y los sube a la Release del tag como `takeit-<target>.tar.gz` (+ `.sha256`).

```sh
# Ejemplo de corte de versión
# 1. Bump version en ray.toml → 0.2.0
# 2. Commit y:
git tag v0.2.0
git push origin v0.2.0
```

## Licencia

Proyecto de laboratorio Rayala / ray-apps. Ver el repositorio para términos.
