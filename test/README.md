# Test Harness

`test/run` is the local and CI entrypoint. It runs the suites sequentially
because they exercise process groups, terminal foreground ownership, signals,
and real loopback listeners. Parallel execution would make those operating
system boundaries contend with one another and turn timing failures into host
load measurements.

## Suite scope

- `install-test` covers the generated checkout installer: the direct wrapper
  and piped curl bootstrap, idempotent reinstall, `BIN_DIR` placement, refusal
  to replace a non-symlink destination, and a working published command.
- `ettun-collision-test` covers retry classification, transport failures,
  provider-assigned port palettes, single-invocation adapters, client identity,
  validation, signal forwarding, parent death, and process-tree cleanup.
- `ettun-custom-test` covers the legacy and capability-negotiated adapter
  contracts, worker status publication, pseudo-terminal authentication,
  Ctrl-C/Ctrl-Z behavior, and the foreground handoff between launcher and
  adapter.
- `ettun-default-test` characterizes the ET argv contract, generated bootstrap
  and remote supervisor, private remote state, authenticated attachment and
  stop flows, stale-owner recovery, local/reverse relay cleanup, fixed reverse
  listener failures, coordinated local/remote port separation, and local port
  probing.
- `ettun-fixture.sh` creates isolated command stubs and shared transport
  fixtures. It is sourced by the suites and is not an independent entrypoint.
- `lib/test.sh` owns the small assertion vocabulary and a guarded per-suite
  temporary root.

Most coverage uses deterministic fake ET, relay, and process-boundary helpers,
so it does not need a configured ET server. Where `ncat` or `socat` is available,
the default suite also exercises real loopback bootstrap and supervisor-stop
paths; otherwise those focused checks report a skip. Python 3 supplies portable
pseudo-terminal and socket fixtures on Linux and macOS.

Run everything with:

```bash
test/run
```

Local runs invoke ShellCheck when it is installed. Shared CI sets
`ETTUN_SKIP_SHELLCHECK=1` for the behavioral matrix because its separate
required inventory job performs the same pinned lint once. To reproduce that
split locally:

```bash
ETTUN_SKIP_SHELLCHECK=1 test/run
awk -F '\t' '$1 == "program" { print $2 }' .github/shellcheck-files.txt |
  xargs shellcheck -x -P SCRIPTDIR
```

Both CI and `test/run` lint the `program` records in
`.github/shellcheck-files.txt`, so the inventory is the single list of shell
programs to update when adding one.

Keep fixtures generic and public. Tests should use reserved example names such
as `gateway.example` and `service.internal`, synthetic tokens, and temporary
paths rather than real hosts, accounts, or deployment details.
