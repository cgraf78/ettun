# ettun

![Tests](https://github.com/cgraf78/ettun/actions/workflows/test.yml/badge.svg?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash Version](https://img.shields.io/badge/bash-%3E%3D3.2-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Termux-lightgrey.svg)](#)

`ettun` exposes a TCP endpoint reachable from an Eternal Terminal server at a
local loopback port. The command stays in the foreground while ET keeps the
underlying connection alive across roaming, sleep, and ordinary network loss.

```console
$ ettun gateway.example 10443 database.internal 443
ettun: localhost:10443 -> database.internal:443 via gateway.example (ET; Ctrl-C to stop)
```

The requested data port (`localhost:10443`) and one dynamically selected,
token-protected control port are opened on the client's loopback interface.
Only loopback listeners are opened on the ET server. `database.internal:443`
does not need to run ET; it only needs to be reachable from `gateway.example`.

## Installation

Clone the repository and install a PATH-visible symlink:

```bash
git clone https://github.com/cgraf78/ettun.git
cd ettun
./install.sh
```

`PREFIX` defaults to `$HOME/.local`; set `BIN_DIR` to override only the binary
directory. Dependency managers can instead expose `bin/ettun` directly. For
example, a shdeps registry entry is:

```text
cgraf78/ettun  github
```

## Usage

```text
ettun VIA LOCAL_PORT TARGET TARGET_PORT
```

- `VIA` is an ET host or SSH-config-style name accepted by the ET client.
- `LOCAL_PORT` is the client-side loopback port to expose.
- `TARGET` and `TARGET_PORT` identify the endpoint reachable from `VIA`.

Press `Ctrl-C` to request authenticated remote cleanup and stop the tunnel. If
ET is disconnected and graceful cleanup is waiting for it to reconnect, press
`Ctrl-C` again to force local teardown. `Ctrl-Z` is intentionally ignored: the
control stream must stay alive for the remote relay's lifetime.

## Requirements

The client needs:

- Bash 3.2 or newer;
- the `et` client, unless a custom transport adapter is configured;
- `base64`, `gzip`, and one of `sha256sum`, `shasum`, or `openssl`;
- standard Unix tools including `awk`, `od`, `ps`, `sed`, and `tee`; and
- `lsof` or `ss` for early detection of an occupied local port.

The `VIA` host needs `/bin/sh`, `etserver`, `flock`, `base64`, `gzip`, a
SHA-256 implementation, and either `socat` or Nmap's `ncat`. `socat` is
preferred because its relay preserves transparent half-close behavior. The
`ncat` fallback is suitable for long-lived full-duplex protocols such as RDP
and VNC, but request/response protocols that half-close before reading a reply
should use `socat`.

## Configuration

| Variable | Purpose |
| --- | --- |
| `ETTUN_ET` | ET client executable name or path. Defaults to `et`. |
| `ETTUN_TRANSPORT` | Executable adapter used instead of invoking `et` directly. |
| `ETTUN_CLIENT_ID` | Stable 32-character lowercase hexadecimal client identity. Normally generated automatically. |

Without `ETTUN_CLIENT_ID`, ettun creates a private identity at
`${XDG_STATE_HOME:-$HOME/.local/state}/ettun/client-id`. The identity is not an
authentication secret. It gives one client a stable remote ownership key so a
later invocation can reclaim that client's interrupted relay for the same local
port without interfering with another client.

### Transport adapter contract

`ETTUN_TRANSPORT` is one executable name or path, not a shell command string.
It is resolved before launch and receives exactly three positional arguments:

1. the `VIA` value;
2. the complete comma-separated ET tunnel specification; and
3. the bounded remote bootstrap command.

The adapter must provide ET-compatible forwarding and remote-command behavior,
remain in the foreground for the connection's lifetime, preserve its exit
status, and leave standard input attached when it needs interactive
authentication. It inherits `ETTUN_RETRY_MARKER`, the exact per-attempt marker
that makes a remote bind collision retryable. Arbitrary adapter errors are not
retried, even when their text happens to mention a collision.

[`examples/transport-et-wrapper`](examples/transport-et-wrapper) is a complete,
tested ET-backed adapter. It is intentionally thin so authentication, signal
handling, retry classification, and remote lifecycle ownership remain with ET
and ettun instead of being reimplemented in the wrapper.

## Lifecycle and security model

Each launch generates a random token and three distinct remote loopback ports:
one for data, one for the held control stream, and one for authenticated
pre-attachment cleanup. The remote POSIX-shell supervisor records its private
state beneath `${XDG_CACHE_HOME:-$HOME/.cache}/ettun`, serializes replacement
with `flock`, and removes only state whose token and process ownership match.
Remote bind collisions retry with a fresh token and port set, up to five
attempts.

The full supervisor is never placed directly in ET's command argument. A small
bootstrap listener accepts a size-bounded payload over the private control
forward, verifies its exact SHA-256 digest and attempt token, and enforces a
deadline before decoding it. All user-controlled host and port values are
validated against narrow grammars. Target values are then interpolated only
into fixed positions in the generated supervisor, while transport values are
passed as argv; no unvalidated user text is evaluated as shell source. Runtime
directories and identity files are created with private modes.

These controls protect ettun's relay protocol and cleanup boundaries. ET still
owns transport encryption, server authentication, and access to the remote
account. A custom transport adapter is trusted code and receives the generated
bootstrap command.

## Development

Run the complete suite with:

```bash
test/run
```

The suites exercise signal and process-tree cleanup, interactive terminal
handoff, collision retry policy, generated remote shell, bootstrap bounds,
state permissions, and both default and custom transports. Python 3 is needed
by the pseudo-terminal and socket fixtures. When ShellCheck is installed, the
runner also lints every program listed in `.github/shellcheck-files.txt`.

See [`test/README.md`](test/README.md) for the test architecture and
[`bin/README.md`](bin/README.md) for the executable's ownership boundaries.

## License

MIT. See [`LICENSE`](LICENSE).
