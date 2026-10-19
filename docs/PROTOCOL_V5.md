# Protocolo takeit v5 — uno o más archivos, con reanudación y PAKE

Contrato del protocolo que implementa takeit desde **0.4.0** (`src/protocol.ray`). Una sesión E2E
transfiere un lote de N ≥ 1 archivos; un solo archivo es el caso N = 1, con la misma máquina de
estados. Complementa [`PLAN.md`](PLAN.md).

> **Historia de versiones.** v1: un archivo, hash encadenado. v2 (0.1.0): un archivo, SHA-256
> real (hasher incremental de raylang, M126). v3: reanudación de un archivo; **nunca se
> publicó** — se integró en v4 antes de cortar 0.2.0. v4 (0.2.0–0.3.0): lotes y reanudación,
> clave `hmac_sha256(sha256(password), salt)`. v5: este documento — lo mismo que v4 tras el
> handshake, que pasa a ser CPace. Un peer de otra versión se rechaza en el hello con un error
> que nombra ambas versiones; no hay camino legacy.

## Decisiones

| Tema | Elección |
|------|----------|
| Unidad de sesión | Una conexión = un lote de archivos |
| Hello en claro | Solo magic, versión, `sid`, `file_count`, `total_size`, `chunk_size`: **ningún nombre** |
| Autenticación | PAKE **CPace** (CPACE-X25519-SHA512) con confirmación de clave en ambos sentidos |
| Manifiesto | Tras el auth, **cifrado** |
| Orden | Secuencial (archivo 0…N−1), sin multiplexar |
| Reanudación | Por archivo: el receptor ofrece lo que ya tiene de cada entrada; el emisor decide el offset |
| Visibilidad en destino | Nada aparece en su sitio hasta que la sesión entera se verifica; entonces se renombran todos |
| Rutas | Relativas POSIX (`dir/a.txt`); se rechazan `..`, `.`, componentes vacíos, absolutas, `\` y NUL |
| Destino | Directorio (`--out DIR`, o el actual); un lote de **un** archivo plano puede nombrar el archivo destino |
| Integridad | SHA-256 por archivo (completo, también al reanudar) + SHA-256 de sesión sobre los digests |
| Contadores AEAD | Uno por dirección, desde 0 |
| Clave de sesión | `hkdf_sha256(salt = sid, ikm = ISK, info = "takeit-v5 session key")`, 32 B |

## Transporte

Cada mensaje es un frame `u32 BE length ‖ payload` (`length` no incluye sus 4 octetos). Un frame
de más de `MAX_FRAME` = 262 400 B se rechaza.

La conexión es un socket TCP directo (el emisor escucha, el receptor conecta) o un tubo a través de
un [rayrelay](https://github.com/ray-language/rayrelay) (`--relay`, desde 0.5.0). En ese caso cada
lado abre antes una línea de control de texto y el protocolo empieza tras ella, sin cambios:

```text
emisor   → "HOST\n"            ← "CODE xxxx-xxxx\n"  …  ← "PEER\n"
receptor → "JOIN xxxx-xxxx\n"  ← "OK\n" | "ERR <motivo>\n"
```

Los bytes que lleguen pegados a la línea de control son del peer y quedan en el buffer de la
conexión. El receptor recibe del usuario un **código unido** `xxxx-xxxx-` + contraseña (24
caracteres sin guiones): los 8 primeros van al relay y el resto es la contraseña de CPace, que el
relay nunca ve. El relay sí ve todo lo que va en claro: el hello (`sid`, número de archivos, tamaño
total, chunk), los mensajes de CPace (que no permiten probar contraseñas) y el tamaño y ritmo del
tráfico cifrado.

## Secuencia

```text
Sender                                Receiver
   |-------- Hello (claro) ------------->|
   |-------- Ya (claro) ---------------->|
   |<------- Yb ‖ Tb (claro) ------------|
   |-------- Ta (claro) ---------------->|
   |-------- Manifest (blob) ----------->|   S#0…
   |<------- Resume (blob) --------------|   R#0…
   |-------- Start (blob) -------------->|
   |  por cada archivo i en 0 … N−1:     |
   |-------- FileBegin(i) -------------->|
   |-------- Data(i)* ------------------>|   solo lo que falta de i
   |-------- FileDone(i) --------------->|
   |-------- SessionDone --------------->|
   |<------- "OK" (claro) ---------------|
```

## Hello (claro)

```text
magic        4 B   "TAKE"
version      1 B   = 4
sid         16 B   aleatorio, nuevo en cada sesión
file_count   4 B   u32 BE   1 … 100 000
total_size   8 B   u64 BE   suma de los tamaños
chunk_size   4 B   u32 BE   1 … 262 144
```

## Autenticación: CPace

[CPace](https://datatracker.ietf.org/doc/draft-irtf-cfrg-cpace/) (borrador 21 de la CFRG),
suite CPACE-X25519-SHA512, en modo iniciador/respondedor: el emisor es A y el receptor es B
(`src/cpace.ray`, con los vectores de prueba del borrador).

| Entrada CPace | Valor en takeit |
|---------------|-----------------|
| PRS | la contraseña normalizada (`password.normalize`: sin guiones ni espacios, minúsculas), UTF-8 |
| CI | `b"takeit"` |
| sid | el `sid` del hello |
| ADa | los bytes exactos del hello: si alguien lo altera en tránsito, la autenticación falla |
| ADb | vacío |

1. Ambos calculan el generador `g = Elligator2(SHA-512(generator_string(PRS, CI, sid)))` y
   eligen un escalar aleatorio nuevo.
2. Emisor → `Ya` (32 B).
3. Receptor: `K = X25519(yb, Ya)` (aborta si `Ya` es de orden bajo), `ISK`, y responde
   `Yb ‖ Tb` (32 + 64 B), con `Tb = HMAC-SHA512(mac_key, lv_cat(Yb, ADb))` y
   `mac_key = SHA-512("CPaceMac" ‖ sid ‖ ISK)`.
4. Emisor: `K = X25519(ya, Yb)`, comprueba `Tb` en tiempo constante; si no cuadra, cierra
   («wrong password?»). Si cuadra, envía `Ta = HMAC-SHA512(mac_key, lv_cat(Ya, ADa))`.
5. Receptor: comprueba `Ta`; si no cuadra o el emisor colgó, aborta.

Ambos derivan la clave de sesión de `ISK` con HKDF. Qué cambia frente a v4:

- **Escuchar la red no sirve para adivinar la contraseña.** En v4, el reto y su HMAC bastaban
  para probar contraseñas offline; en v5 nada de lo que pasa por el cable se puede comprobar
  sin resolver un Diffie-Hellman.
- **Un atacante activo tiene un intento por sesión**, y el emisor solo acepta una conexión.
- **Secreto hacia adelante**: cada sesión usa escalares nuevos; la contraseña filtrada después
  no descifra una sesión grabada.
- Limitación conocida: el mapeo Elligator2 usa `std/bigint`, que no es de tiempo constante, así
  que su duración depende de la contraseña. Es un cálculo por sesión; el riesgo práctico es
  para un atacante con medidas de tiempo finas sobre la máquina.

## Frames cifrados

- ChaCha20-Poly1305 con la `key` de 32 B.
- **Nonce** (12 B) = `u64 BE frame_index ‖ u32 BE dir`, con `dir` = 0 para los frames del
  emisor y 1 para los del receptor. Ambos cifran con la misma clave; el tag de dirección hace
  disjuntos sus espacios de nonces. `frame_index` cuenta por dirección desde 0.
- **AAD** = `u64 BE frame_index ‖ u32 BE file_index ‖ u64 BE total_size`, con
  `file_index = 0xFFFFFFFF` en los frames que no son de un archivo (blobs, SessionDone). Un
  frame no se puede reordenar, mover a otro archivo ni a otra sesión.
- **Plaintext** = `kind: u8 ‖ body`.

| `kind` | Nombre | Dirección | `file_index` en AAD |
|--------|--------|-----------|---------------------|
| `0x10` | Manifest | S → R | ninguno |
| `0x14` | Resume | R → S | ninguno |
| `0x15` | Start | S → R | ninguno |
| `0x11` | FileBegin | S → R | i |
| `0x01` | Data | S → R | i |
| `0x12` | FileDone | S → R | i |
| `0x13` | SessionDone | S → R | ninguno |

### Blobs (Manifest, Resume, Start)

Pueden pasar de un frame (100 000 entradas), así que viajan troceados: el primer frame lleva
`u64 BE longitud ‖ primer trozo`, los siguientes del mismo `kind` el resto, en trozos de hasta
256 KiB. Longitud máxima: 128 MiB.

### Manifest

```text
u32  entry_count            // = file_count del Hello
repetir entry_count:
  u32   path_len            // ≤ 1024
  bytes path                // UTF-8, relativa
  u64   size
```

El receptor lo **valida antes de tocar el disco**: número de entradas = `file_count`, suma de
tamaños = `total_size`, cada ruta segura (`paths.check`) y única.

### Resume

```text
u32  entry_count
repetir: u64 offset ‖ 32 B sha256(primeros offset bytes)
```

Por cada entrada, lo que el receptor tiene en `<destino>.takeit.partial`: su longitud si es ≤
`size` (si no, o con `--fresh`, `0` y el SHA-256 vacío).

### Start

```text
u32  entry_count
repetir: u64 offset
```

Por cada entrada, el emisor hashea los primeros `offset` bytes de **su** archivo: si coinciden con
la oferta, envía desde ahí; si no (otro archivo con el mismo nombre, una cola rota), `0`. El
receptor acepta solo `0` o exactamente su oferta.

### FileBegin · Data · FileDone

- FileBegin: `u32 file_index` (eco, en orden).
- Data: `bytes` (1 … chunk_size). La suma por archivo es `size − offset`. Un archivo vacío o ya
  completo va FileBegin → FileDone sin Data.
- FileDone: `u32 file_index ‖ 32 B sha256(archivo completo)`. Ambos lados alimentan su hasher
  con el prefijo reanudado antes de la cola. El receptor verifica digest y tamaño y hace
  `fs.sync`; el archivo **sigue como parcial**.

### SessionDone

`u32 file_count ‖ 32 B sha256(digest_0 ‖ … ‖ digest_N−1)`. Si cuadra, el receptor renombra
todos los parciales a su destino y responde `OK` en claro.

## Destino y confinamiento (receptor)

- Antes de escribir nada, el receptor comprueba que puede guardar el lote **fielmente en su
  sistema**: en Windows, que cada nombre se pueda crear (sin `<>:"|?*` ni controles, sin nombres
  de dispositivo como `CON` o `nul.txt`, sin punto o espacio final); en Windows y macOS (NTFS y
  APFS ignoran mayúsculas), que no haya dos rutas que solo difieran en mayúsculas. Si no, error
  con el nombre culpable.
- Las rutas LOCALES usan el separador del sistema (`\` en Windows); las del manifiesto, siempre `/`.
- Un lote de un archivo sin `/` en la ruta, con `--out` que no es un directorio existente ni
  acaba en `/`: `--out` es el archivo destino (como v1/v2).
- En cualquier otro caso `--out` (o `.`) es el directorio base: cada entrada va a
  `base/path`, creando los directorios intermedios.
- Antes de ofrecer y otra vez tras crear los directorios, el padre de cada destino tiene que
  resolver **dentro** de la base (`fs.is_within_real`): un enlace simbólico dentro de la carpeta
  de salida que apunte fuera no sirve para escribir fuera.
- Un parcial que no es un archivo regular (un enlace plantado donde iría) se rechaza, nunca se
  escribe a través de él.

## Fallos y limpieza

| Fallo | Qué queda en el receptor |
|-------|--------------------------|
| Red, timeout, emisor cerrado, AEAD de un frame | **todos** los parciales, completos incluidos: la siguiente sesión envía solo lo que falta |
| Digest o tamaño de un archivo | ese parcial se borra; los demás se quedan |
| Manifiesto inválido, ruta fuera de la base | nada se ha escrito |

Los archivos finales solo aparecen tras SessionDone, así que una sesión cortada nunca deja un
lote a medias mezclado con archivos «buenos».

## Emisor: entradas

- Un argumento archivo va con su nombre; un directorio, recursivamente bajo **su** nombre
  (`fotos/2026/a.jpg`), como `scp -r`. Los nombres salen de la ruta real (`.` → el nombre del
  directorio).
- Un argumento que es un enlace simbólico se sigue; los enlaces dentro de directorios se
  omiten (se avisa en stderr).
- Dos entradas que llegarían con la misma ruta son un error, igual que un nombre que no pasa
  `paths.check` (p. ej. con `\`).
- Si un archivo cambia de tamaño entre el manifiesto y su envío, la sesión aborta.

## Progreso

Una línea en stderr sobre `total_size`: `sending 2/205 data/big2.bin  140 MiB / 300 MiB (46%) …`.
El prefijo reanudado cuenta en el porcentaje, no en la velocidad ni en el ETA.

## Fuera de alcance

- Hole punching UDP (conexión directa a través de NAT); el relay solo copia bytes.
- Compresión, delta por bloques, envío en paralelo.
- Metadatos (mtime, permisos) y directorios vacíos.
