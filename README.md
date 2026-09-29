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

Install with a checkout-backed curl bootstrap:

```bash
curl -fsSL https://raw.githubusercontent.com/cgraf78/ettun/main/install.sh | bash
```

This keeps a durable managed checkout under `$XDG_DATA_HOME` when that path is
absolute, or under `$HOME/.local/share` otherwise, and publishes a link to its
`ettun` command. It does not use a release asset or copy a second runtime tree.
Git and Bash 3.2 or newer are required.

To choose and manage the checkout yourself instead:

```bash
git clone https://github.com/cgraf78/ettun.git
cd ettun
bash install.sh
```

Keep that checkout in place: the installer publishes a symlink to `bin/ettun`,
so updating the checkout updates the installed command without creating a
second program copy. Rerunning the curl command safely fast-forwards its clean
managed checkout before republishing the same link.

`PREFIX` defaults to `$HOME/.local`; set `BIN_DIR` to override only the binary
directory. The installer retargets an existing symlink but refuses to replace a
real file or directory. Dependency managers can instead expose `bin/ettun`
directly. For example, a shdeps registry entry is:

```text
cgraf78/ettun  github
```

## Usage

```text
ettun VIA LOCAL_PORT TARGET TARGET_PORT
ettun VIA [--jump-host JUMP_HOST]
               [--local LOCAL_PORT TARGET TARGET_PORT]
               [--reverse REMOTE_PORT TARGET TARGET_PORT]
```

- `VIA` is an ET host or SSH-config-style name accepted by the ET client.
- `--jump-host` selects ET's native single-hop jump mode. It is available only
  with stock ET, not with a custom `ETTUN_TRANSPORT` adapter.
- A local route exposes an endpoint reachable from `VIA` on the client's
  loopback `LOCAL_PORT`. The original four-argument form remains equivalent to
  one `--local` route.
- A reverse route exposes an endpoint reachable from the client on
  `VIA`'s loopback `REMOTE_PORT`.
- The explicit form accepts one local route, one reverse route, or both. Both
  routes share one ET connection and one foreground lifecycle.

For a relay whose ET connection must cross one SSH jump host:

```bash
ettun relay.example --jump-host jump.example \
  --local 10443 database.internal 443
```

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
- `ss` (preferred) or `lsof` for early detection of an occupied local port.

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
| `ETTUN_REMOTE_PORT_SLOT_V1` | Provider-assigned integer from 0 through 818 that selects one disjoint generated-port palette. |
| `ETTUN_TRANSPORT_SINGLE_INVOCATION_V1` | Prevalidated provider assertion that the selected adapter must not be reinvoked. The only accepted value is `1`. |

Without `ETTUN_CLIENT_ID`, ettun creates a private identity at
`${XDG_STATE_HOME:-$HOME/.local/state}/ettun/client-id`. The identity is not an
authentication secret. It gives one client a stable remote ownership key so a
later invocation can reclaim that client's interrupted relay for the same local
port without interfering with another client.

### Transport adapter contract

`ETTUN_TRANSPORT` is one executable name or path, not a shell command string.
The original local-only form preserves the legacy three-argument invocation:

1. the `VIA` value;
2. the complete comma-separated ET tunnel specification; and
3. the bounded remote bootstrap command.

Before using a custom adapter for a reverse route, ettun invokes
`ADAPTER --ettun-capabilities` with standard input closed. The query must be
noninteractive and print one lowercase capability token per line. An adapter
which prints `connect-v2` is invoked as:

```text
ADAPTER --ettun-connect-v2 VIA TUNNEL_SPEC REVERSE_SPEC REMOTE_COMMAND
```

`TUNNEL_SPEC` contains the ordinary ET mappings, including ettun's private
control mapping. `REVERSE_SPEC` contains the explicit reverse ET mapping. A
legacy adapter remains supported for local-only routes, but reverse routes fail
before connection unless `connect-v2` is declared.

The adapter must provide ET-compatible forwarding and remote-command behavior,
remain in the foreground for the connection's lifetime, preserve its exit
status, and leave standard input attached when it needs interactive
authentication. It inherits `ETTUN_RETRY_MARKER`, the exact per-attempt marker
that makes a remote bind collision retryable. Arbitrary adapter errors are not
retried, even when their text happens to mention a collision.

A `connect-v2` adapter which cannot safely be invoked again without repeating
authentication or rebuilding private session state should also print
`single-invocation-v1`. If that adapter reports an authenticated random relay
collision, ettun exits with status 75 and asks the operator to restart instead
of invoking it a second time. Stock ET and adapters which omit this capability
retain the bounded five-attempt collision retry.

An orchestrator which has already authenticated that capability may pass
`ETTUN_TRANSPORT_SINGLE_INVOCATION_V1=1`, including for a local-only route whose
legacy adapter cannot safely receive a capability probe. The assertion only
narrows retry behavior; ettun removes it before invoking the adapter.

[`examples/transport-et-wrapper`](examples/transport-et-wrapper) is a complete,
tested ET-backed adapter. It is intentionally thin so authentication, signal
handling, retry classification, and remote lifecycle ownership remain with ET
and ettun instead of being reimplemented in the wrapper.

## Lifecycle and security model

Each launch generates a random token and distinct remote loopback ports for
data, the held control stream, and authenticated pre-attachment cleanup. A
reverse route adds a random ET transport port; the remote supervisor owns the
stable requested loopback listener and proxies it into that random transport
port. This lets authenticated replacement reclaim the stable listener without
depending on a stale ET session reconnecting first.

Standalone launches seed generated ports from the operating system random
source. A provider managing concurrent legs can assign each one a distinct
`ETTUN_REMOTE_PORT_SLOT_V1`; the 819 version-one slots partition all generated
data, control, stop, reverse-transport, and local-control candidates across the
five attempts. The value is consumed by the engine and is not inherited by a
transport adapter. Collisions with unrelated processes remain authenticated
and fail or retry under the same adapter policy.

The supervisor records private state beneath
`${XDG_CACHE_HOME:-$HOME/.cache}/ettun`, serializes replacement with `flock`,
and removes only state whose token and process ownership match. Random relay
bind collisions retry with a fresh token and port set, up to five attempts,
except for an adapter declaring `single-invocation-v1` as described above. A
collision on the requested fixed reverse port fails immediately and actionably.

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
