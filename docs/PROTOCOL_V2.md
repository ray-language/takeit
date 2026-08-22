# Protocolo takeit v2 — varios archivos

Diseño de frames para transferir **uno o más archivos** en una sola sesión E2E.
Complementa `PLAN.md`. **Aún no implementado**; este doc es el contrato antes de codear.

## Objetivos

- Misma contraseña y un solo `host:port` (o relay futuro) para N archivos.
- Streaming por archivo (sin cargar todo en RAM).
- Progreso global + archivo actual.
- Compatibilidad: un peer v1 solo habla `version = 1`; v2 usa `version = 2`.

## Decisiones

| Tema | Elección v2 |
|------|-------------|
| Unidad de sesión | Una conexión = un lote de archivos |
| Manifiesto | Tras auth, **cifrado** (nombres no van en claro en la red) |
| Hello en claro | Solo: magic, versión, salt, `file_count`, `total_size`, `chunk_size` |
| Orden | Secuencial (archivo 0…N−1); sin multiplexar en paralelo |
| Error en un archivo | **Abortar la sesión** entera (parciales se borran) |
| Rutas | Relativas POSIX (`dir/a.txt`); rechazar `..`, absolutas y `\` |
| Destino receptor | Directorio (`--out DIR`); si es un solo archivo, se permite fichero como hoy |
| Hash por archivo | Igual que v1: encadenado `sha256(state ‖ sha256(chunk))` |
| Contador AEAD | Un solo contador monótono de frames cifrados en toda la sesión |
| KDF | Sin cambio: `hmac_sha256(sha256(password), salt ‖ "takeit-v1")` |

## Transporte (sin cambio)

Cada mensaje de aplicación es un frame:

```text
u32 BE length ‖ payload
```

`length` = tamaño de `payload` (no incluye los 4 octetos). Límite: `MAX_FRAME` (≥ `chunk_size` + overhead AEAD).

## Secuencia

```text
Sender                         Receiver
   |                              |
   |-------- Hello (claro) ------>|
   |-------- Auth challenge ----->|
   |<------- Auth response -------|
   |-------- Manifest (AEAD) ---->|
   |                              |
   |  for file i in 0 .. N-1:     |
   |-------- FileBegin (AEAD) --->|
   |-------- Data (AEAD)* ------->|
   |-------- FileDone (AEAD) ---->|
   |                              |
   |-------- SessionDone (AEAD) ->|
   |<------- SessionACK ----------|
```

Un solo archivo es el caso N=1 (misma máquina de estados).

## Tipos de frame (byte 0 del plaintext cifrado)

Tras el auth, **todo** el payload útil viaja dentro de AEAD. El plaintext de cada frame cifrado empieza por un `kind: u8`:

| `kind` | Nombre | Cuándo |
|--------|--------|--------|
| `0x10` | Manifest | Una vez, tras auth |
| `0x11` | FileBegin | Antes de los datos de cada archivo |
| `0x01` | Data | Trozo de plaintext del archivo actual |
| `0x12` | FileDone | Tras el último Data del archivo |
| `0x13` | SessionDone | Tras el último FileDone |
| `0x02` | Done (legacy v1) | No se usa en v2 |

Los frames **en claro** (antes/durante auth) no usan `kind` AEAD:

| Fase | Payload |
|------|---------|
| Hello | ver abajo |
| Auth challenge | 16 B nonce |
| Auth response | 32 B HMAC |
| SessionACK | literal `OK` (o futuro `ERR` + motivo) — **en claro** tras SessionDone, o cifrado; v2: **en claro** `OK` como v1 |

## Hello (claro)

```text
magic        4 B   "TAKE"
version      1 B   = 2
salt        16 B
file_count   4 B   u32 BE   (≥ 1)
total_size   8 B   u64 BE   (suma de tamaños)
chunk_size   4 B   u32 BE
```

Notas:

- No incluye nombres (privacidad / simplicidad del hello).
- El receptor puede rechazar si `file_count` o `total_size` exceden límites locales (futuro: flags CLI).

## Auth (igual que v1)

1. Sender → nonce 16 B (frame).
2. Ambos: `mac = hmac_sha256(key, "auth" ‖ nonce)`.
3. Receiver → `mac` (frame).
4. Sender verifica; si falla → cierre.

## Frames cifrados (AEAD)

### Parámetros comunes

- Algoritmo: ChaCha20-Poly1305.
- `key`: 32 B (KDF).
- `nonce`: 12 B = `u64 BE frame_index ‖ 0x00000000`.
- `frame_index`: empieza en **0** en el primer frame cifrado (Manifest) y sube en cada seal/open.
- `aad` (asociado):

```text
u8  kind
u64 BE frame_index
u32 BE file_index     // 0xFFFFFFFF si no aplica (Manifest, SessionDone)
u64 BE total_size     // del Hello
```

Así un frame no se puede reordenar ni reutilizar entre archivos.

### `0x10` Manifest

Plaintext:

```text
u8   0x10
u32  entry_count      // = file_count del Hello
// repeat entry_count:
  u32  path_len
  bytes path          // UTF-8, relativa
  u64  size
```

Reglas de `path`:

- Separador `/`; sin prefijo `/`; sin `..` como componente; sin `\` ni NUL.
- Única en el manifiesto (case-sensitive).
- Longitud total del path ≤ 1024 B; `entry_count` ≤ 100_000 (límite soft).

El receptor crea el directorio base y, al escribir, `join(out_dir, path)` tras validar.

### `0x11` FileBegin

```text
u8   0x11
u32  file_index       // 0 .. N-1, en orden
u32  path_len
bytes path            // debe coincidir con manifiesto[file_index]
u64  size             // idem
```

### `0x01` Data

```text
u8    0x01
bytes chunk           // 1 .. chunk_size (último puede ser menor; size 0 solo si archivo vacío sin Data)
```

- Archivo vacío: FileBegin → FileDone **sin** Data.
- Suma de lengths de Data de ese `file_index` = `size`.

### `0x12` FileDone

```text
u8    0x12
u32   file_index
bytes digest          // 32 B streamhash del plaintext de ese archivo
```

Tras verificar digest y tamaño, el receptor hace rename atómico del `.takeit.partial` al path final.

### `0x13` SessionDone

```text
u8    0x13
u32   file_count      // eco del Hello (sanity check)
bytes session_digest  // 32 B: streamhash sobre la concatenación de digests de cada FileDone
                      //   h = init()
                      //   for d in file_digests: h = update(h, d)
```

### SessionACK

Frame en claro, payload `OK` (2 B). Si el receptor abortó antes, cierra sin ACK.

## Abort y limpieza

Si falla auth, AEAD, path inválido, checksum o I/O:

1. Receptor borra todos los `*.takeit.partial` de la sesión y archivos ya renombrados de **esta** sesión (lista en memoria).
2. Cierra el socket.
3. Emisor reporta error al fallar write/read o al no recibir ACK.

No hay reanudación (resume) en v2.

## UX CLI (propuesta)

```text
takeit send ./a.pdf ./fotos/ ./b.zip
→ Password: …
→ Waiting on 0.0.0.0:7421 …
→ (3 files, 1.2 GiB)

takeit recv --host H --port P --password X --out ./inbox
→ receiving 2/3  fotos/img.jpg  …
→ Saved: ./inbox/ (3 files, 1.2 GiB)
```

- Argumentos que son directorios: se expanden a archivos regulares (no seguir symlinks por defecto).
- Un solo path archivo + `--out file` sigue permitido (como v1).
- Varios archivos → `--out` debe ser directorio (o se crea).

## Progreso

- Contadores: `bytes_done / total_size`, más `file_index+1 / file_count` y path actual en la línea de progreso.
- Labels en inglés (`sending` / `receiving`), según la convención del proyecto.

## Migración desde v1

| Peer A | Peer B | Resultado |
|--------|--------|-----------|
| v1 | v1 | Sin cambio |
| v2 | v2 | Este documento |
| v2 send | v1 recv | v1 ve `version=2` → error "unsupported version" |
| v1 send | v2 recv | v2 puede **aceptar version=1** (camino legacy de un archivo) o rechazar; **recomendación**: v2 recv acepta v1 |

Implementación sugerida: `protocol.ray` con `VERSION = 2` y rama `if version == 1 { … }` en el receptor.

## Fuera de alcance v2

- Relay / códigos cortos (fase 6 del plan).
- Compresión, delta, resume.
- Envío en paralelo de varios archivos.
- Metadatos extendidos (mtime, modos Unix).

## Checklist de implementación

- [ ] Codificar/decodificar Hello v2 + Manifest
- [ ] Validación de paths
- [ ] Bucle FileBegin → Data* → FileDone
- [ ] SessionDone + session_digest
- [ ] Expansión de directorios en CLI
- [ ] Progreso multi-archivo
- [ ] Tests: 1 archivo, N archivos, vacío, path traversal rechazado, abort a mitad
- [ ] Recv compatible con Hello v1 (opcional pero recomendado)
