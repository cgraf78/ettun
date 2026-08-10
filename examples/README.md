# Transport adapter example

`transport-et-wrapper` is a complete, intentionally thin implementation of
the `ETTUN_TRANSPORT` contract. It accepts exactly the three arguments supplied
by ettun, converts them to ET's argv interface, stays in the foreground, and
preserves standard input and the transport exit status through `exec`.

Use it directly from a checkout:

```sh
ETTUN_TRANSPORT=/path/to/ettun/examples/transport-et-wrapper \
  ettun relay.example 5901 desktop.example 5900
```

`ETTUN_ET` may select another ET executable. The adapter deliberately does not
log its arguments: the third argument is an authenticated remote bootstrap and
should not be copied into routine logs. Custom adapters are trusted code and
must provide equivalent forwarding, remote-command, foreground, and
interactive-input behavior.

The test suite invokes this exact file both through ettun and with a small
ET-compatible test double. That protects the documented argv, stdin, signal,
and exit-status behavior from drift.
