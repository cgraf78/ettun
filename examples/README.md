# Transport adapter example

`transport-et-wrapper` is a complete, intentionally thin implementation of
the `ETTUN_TRANSPORT` contract. It supports the legacy three-argument
local-only invocation and declares `connect-v2` for explicit reverse routes.
Both forms are converted to ET's argv interface, stay in the foreground, and
preserve standard input and the transport exit status through `exec`.

Use it directly from a checkout:

```sh
ETTUN_TRANSPORT=/path/to/ettun/examples/transport-et-wrapper \
  ettun relay.example 5901 desktop.example 5900

ETTUN_TRANSPORT=/path/to/ettun/examples/transport-et-wrapper \
  ettun relay.example --local 5901 desktop.example 5900 \
    --reverse 22022 127.0.0.1 22
```

`ETTUN_ET` may select another ET executable. The adapter deliberately does not
log its arguments: the third argument is an authenticated remote bootstrap and
should not be copied into routine logs. Custom adapters are trusted code and
must provide equivalent forwarding, remote-command, foreground, and
interactive-input behavior.

The test suite invokes this exact file through both adapter contracts and with
a small ET-compatible test double. That protects the documented capability,
argv, stdin, signal, and exit-status behavior from drift.
