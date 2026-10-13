#!/usr/bin/env bash
# ettun-fixture.sh - shared setup for ET tunnel behavior shards.

# shellcheck disable=SC1091,SC2016,SC2034
set -o pipefail
export NO_COLOR=1

# A non-interactive shell starts an asynchronous simple command (`suite &`)
# with SIGINT and SIGQUIT ignored, and a Bash started that way can neither
# trap nor reset them. Every ettun launched beneath would then ignore the
# Ctrl-C the terminal cases send, and wait out their deadlines. Re-execute
# the suite once with default dispositions, which only Python can restore;
# Python also detects them, since `trap -p` reporting varies across Bashes.
# Python itself ignores SIGPIPE and SIGXFSZ, so reset those before exec too,
# and unblock all four in case the caller blocked them. A one-shot marker
# bounds the re-exec even if a host defeats the checks below.
# A caller that ignores SIGPIPE (systemd does by default) also changes how
# pipelines behave; Python cannot see that, since it ignores SIGPIPE itself,
# but a writer into a closed pipe shows it.
signals_need_reset=0
if command -v yes >/dev/null 2>&1; then
  yes 2>/dev/null | head -n 1 >/dev/null
  ((PIPESTATUS[0] == 141)) || signals_need_reset=1
fi
if [[ -z "${ETTUN_TEST_SIGNALS_RESET:-}" ]] && {
  ((signals_need_reset == 1)) || python3 -I -c '
import signal, sys
ignored = (signal.getsignal(signal.SIGINT), signal.getsignal(signal.SIGQUIT))
sys.exit(0 if signal.SIG_IGN in ignored else 1)
'
}; then
  export ETTUN_TEST_SIGNALS_RESET=1
  exec python3 -I -c '
import os, signal, sys
names = ("SIGINT", "SIGQUIT", "SIGPIPE", "SIGXFSZ")
for name in names:
    signal.signal(getattr(signal, name), signal.SIG_DFL)
signal.pthread_sigmask(signal.SIG_UNBLOCK, {getattr(signal, name) for name in names})
os.execv(sys.argv[1], sys.argv[1:])
' "$BASH" "$0" "$@"
fi
unset ETTUN_TEST_SIGNALS_RESET signals_need_reset
# ettun hands a terminal on its standard input to the transport. Cases that
# need a terminal open their own pseudo-terminal, so never let the caller's
# terminal reach the rest.
exec </dev/null

# Every time bound in the suites derives from two exported values, which a
# static check in ettun-collision-test enforces:
# - ETTUN_TEST_WAIT_SECONDS (WAIT_DEADLINE_SECONDS here) bounds each "wait
#   until X happens" poll. A generous bound costs time only when a case
#   fails; a tight one turns CPU contention on a shared runner into false
#   failures, since each 0.1s sleep and every probe can take far longer than
#   nominal.
# - ETTUN_TEST_TIME_SCALE multiplies the deliberately short bounds, such as
#   a per-attempt connect timeout. Slow hosts and CI can raise it (a
#   positive integer, default 1); the shared wait scales with it.
ETTUN_TEST_TIME_SCALE=${ETTUN_TEST_TIME_SCALE:-1}
if [[ ! $ETTUN_TEST_TIME_SCALE =~ ^[1-9][0-9]*$ ]]; then
  printf 'ettun tests: ETTUN_TEST_TIME_SCALE must be a positive integer\n' >&2
  exit 2
fi
WAIT_DEADLINE_SECONDS=$((20 * ETTUN_TEST_TIME_SCALE))
export ETTUN_TEST_TIME_SCALE ETTUN_TEST_WAIT_SECONDS=$WAIT_DEADLINE_SECONDS

ETTUN_TEST_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/test.sh
. "$ETTUN_TEST_ROOT/test/lib/test.sh"

SCRIPT="$ETTUN_TEST_ROOT/bin/ettun"
tmp=$(_tmpdir) || exit 1
# Some generated remote-shell fixtures honor TMPDIR just like a real remote
# host.  Pin it beneath this suite directory so the harness's guarded EXIT trap
# owns every test artifact, including artifacts left by an interrupted test.
TMPDIR="$tmp"
export TMPDIR
bin="$tmp/bin"
test_home="$tmp/home"
log="$tmp/commands.log"
test_python=$(python3 -c 'import sys; print(sys.executable)')
port_probe_error="$tmp/port-probe.error"
real_bash=$(command -v bash)
# Fixture PATHs intentionally exclude user-installed commands so missing-tool
# cases stay honest. Preserve the historical lookup order on FHS hosts, while
# adding Bash's actual directory when a platform such as Termux keeps all of
# its core tools below an app prefix and has no /usr/bin or /bin directory.
real_bash_dir=${real_bash%/*}
test_system_path=/usr/bin:/bin
test_extended_system_path=/usr/local/bin:/usr/bin:/bin
case ":$test_system_path:" in
  *":$real_bash_dir:"*) ;;
  *) test_system_path="$real_bash_dir:$test_system_path" ;;
esac
case ":$test_extended_system_path:" in
  *":$real_bash_dir:"*) ;;
  *) test_extended_system_path="$real_bash_dir:$test_extended_system_path" ;;
esac
real_ps=$(command -v ps)
printf -v real_ps_q '%q' "$real_ps"
real_mkdir=$(command -v mkdir)
printf -v real_mkdir_q '%q' "$real_mkdir"
real_mv=$(command -v mv)
printf -v real_mv_q '%q' "$real_mv"
printf -v test_python_q '%q' "$test_python"
mkdir -p "$bin" "$test_home"
# ettun prefers local control ports of the parity Linux connect() avoids: the
# opposite of ip_local_port_range's start, or odd where that is unknown.
preferred_parity=1
if [[ -r /proc/sys/net/ipv4/ip_local_port_range ]] &&
  read -r range_low _ </proc/sys/net/ipv4/ip_local_port_range &&
  [[ $range_low =~ ^[0-9]+$ ]]; then
  preferred_parity=$(((10#$range_low + 1) % 2))
fi

_write_stub() {
  local path="$1"
  shift
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$@"
  } >"$path"
  chmod +x "$path"
}

# Generated control ports (49152+) overlap the kernel's ephemeral range, where
# any client connection on the host can already own the port a fixture will
# later bind. The default path therefore performs the same bind the fixtures
# will, so ettun skips any candidate that bind would reject. Bake in the suite
# interpreter: most scenarios that launch ettun directly rather than through
# _run_ettun do not pass ETTUN_TEST_PYTHON, and an empty interpreter name used
# to report every candidate as free.
_write_stub "$bin/lsof" \
  'if [[ " $* " == *" -sTCP:LISTEN "* ]]; then' \
  '  listener_port=' \
  '  [[ -z "${ETTUN_TEST_LSOF_LISTENER_FILE:-}" || ! -r "$ETTUN_TEST_LSOF_LISTENER_FILE" ]] ||' \
  '    read -r listener_port <"$ETTUN_TEST_LSOF_LISTENER_FILE"' \
  '  for arg in "$@"; do' \
  '    if [[ -n "$listener_port" && "$arg" == "-iTCP:$listener_port" ]]; then' \
  '      printf "p12345\\nn127.0.0.1:%s\\n" "$listener_port"' \
  '      exit 0' \
  '    fi' \
  '  done' \
  '  exit 1' \
  'fi' \
  'if [[ -n "${ETTUN_TEST_LSOF_OWNER_FILE:-}" && -r "$ETTUN_TEST_LSOF_OWNER_FILE" ]]; then' \
  '  read -r owner_port <"$ETTUN_TEST_LSOF_OWNER_FILE"' \
  '  for arg in "$@"; do' \
  '    if [[ "$arg" == "-iTCP:$owner_port" ]]; then' \
  '      printf "p12345\\nn127.0.0.1:%s->127.0.0.1:443\\n" "$owner_port"' \
  '      exit 0' \
  '    fi' \
  '  done' \
  'fi' \
  'if [[ -n "${ETTUN_TEST_LSOF_ESTABLISHED_PORT:-}" ]]; then' \
  '  for arg in "$@"; do' \
  '    if [[ "$arg" == "-iTCP:$ETTUN_TEST_LSOF_ESTABLISHED_PORT" ]]; then' \
  '      printf "p12345\\nn127.0.0.1:%s->127.0.0.1:443\\n" "$ETTUN_TEST_LSOF_ESTABLISHED_PORT"' \
  '      exit 0' \
  '    fi' \
  '  done' \
  'fi' \
  'if [[ -n "${ETTUN_TEST_LSOF_REMOTE_PORT:-}" ]]; then' \
  '  for arg in "$@"; do' \
  '    if [[ "$arg" == "-iTCP:$ETTUN_TEST_LSOF_REMOTE_PORT" ]]; then' \
  '      printf "p12345\\nn127.0.0.1:54321->127.0.0.1:%s\\n" "$ETTUN_TEST_LSOF_REMOTE_PORT"' \
  '      exit 0' \
  '    fi' \
  '  done' \
  'fi' \
  'if [[ -n "${ETTUN_TEST_LSOF_EXIT:-}" ]]; then' \
  '  if [[ "$ETTUN_TEST_LSOF_EXIT" == 0 ]]; then' \
  '    for arg in "$@"; do' \
  '      [[ "$arg" == -iTCP:* ]] && printf "p12345\\nn*:%s\\n" "${arg#-iTCP:}"' \
  '    done' \
  '  fi' \
  '  exit "$ETTUN_TEST_LSOF_EXIT"' \
  'fi' \
  "test_python=$test_python_q" \
  'probe_port=' \
  'for arg in "$@"; do [[ "$arg" == -iTCP:* ]] && probe_port=${arg#-iTCP:}; done' \
  'if [[ "$probe_port" =~ ^[0-9]+$ ]] && ((probe_port >= 49152)); then' \
  '  "${ETTUN_TEST_PYTHON:-$test_python}" - "$probe_port" <<PY' \
  'import errno' \
  'import os' \
  'import socket' \
  'import sys' \
  'probe = None' \
  'try:' \
  '    probe = socket.socket()' \
  '    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)' \
  '    probe.bind(("127.0.0.1", int(sys.argv[1])))' \
  'except OSError as error:' \
  '    if error.errno == errno.EADDRINUSE:' \
  '        print(f"p1\\nn127.0.0.1:{sys.argv[1]}")' \
  '        sys.exit(0)' \
  '    message = f"port {sys.argv[1]}: {error}\\n"' \
  '    error_log = os.environ.get("ETTUN_TEST_PORT_PROBE_ERROR")' \
  '    if error_log:' \
  '        with open(error_log, "a", encoding="utf-8") as output:' \
  '            output.write(message)' \
  '    else:' \
  '        sys.stderr.write(message)' \
  '    sys.exit(2)' \
  'finally:' \
  '    if probe is not None:' \
  '        probe.close()' \
  'sys.exit(1)' \
  'PY' \
  '  exit $?' \
  'fi' \
  'exit 1'
# ettun prefers a real perl bind probe, then ss, then lsof. The probe sees the
# host's real sockets, so the stub reports it inconclusive and fixed fixture
# ports stay host-independent on the socket-table fallback. Bind-probe tests
# put the real perl first through perl_bin.
_write_stub "$bin/perl" 'exit 2'
perl_bin="$tmp/perl-bin"
mkdir -p "$perl_bin"
real_perl=$(command -v perl 2>/dev/null || true)
[[ -z "$real_perl" ]] || ln -s "$real_perl" "$perl_bin/perl"
# A failing ss keeps the lsof-driven fixtures above on that path wherever a
# real ss would otherwise be visible (Ubuntu installs it in /usr/bin).
_write_stub "$bin/ss" 'exit 1'
ss_bin="$tmp/ss-bin"
mkdir -p "$ss_bin"
ln -s "$real_bash" "$ss_bin/bash"
_write_stub "$ss_bin/ss" \
  'if [[ " $* " == *" -atn "* && " $* " == *" sport = :$ETTUN_TEST_SS_LISTENER_PORT "* ]]; then' \
  '  printf "LISTEN 0 128 127.0.0.1:%s 0.0.0.0:*\\n" "$ETTUN_TEST_SS_LISTENER_PORT"' \
  'fi' \
  'if [[ " $* " != *" exclude time-wait "* && " $* " == *" sport = :$ETTUN_TEST_SS_TIME_WAIT_PORT "* ]]; then' \
  '  printf "TIME-WAIT 0 0 127.0.0.1:%s 127.0.0.1:40000\\n" "$ETTUN_TEST_SS_TIME_WAIT_PORT"' \
  'fi'
# A loopback probe stub for ss's empty-answer path.
nc_bin="$tmp/nc-bin"
mkdir -p "$nc_bin"
_write_stub "$nc_bin/nc" 'exit "${ETTUN_TEST_NC_EXIT:-1}"'
_write_stub "$bin/et" \
  'printf "et\n" >>"$ETTUN_TEST_LOG"' \
  'previous= tunnel_spec=' \
  'for arg in "$@"; do' \
  '  printf "<%s>\n" "$arg" >>"$ETTUN_TEST_LOG"' \
  '  if [[ "$previous" == --command ]]; then printf "%s\n" "$arg" >"$ETTUN_TEST_REMOTE_COMMAND"; fi' \
  '  if [[ "$previous" == -t ]]; then tunnel_spec=$arg; fi' \
  '  previous="$arg"' \
  'done' \
  'printf "%s\n" "--" >>"$ETTUN_TEST_LOG"' \
  'count=0' \
  '[[ -r "$ETTUN_TEST_COUNT" ]] && read -r count <"$ETTUN_TEST_COUNT"' \
  'count=$((count + 1))' \
  'printf "%s\n" "$count" >"$ETTUN_TEST_COUNT"' \
  'if ((count <= ${ETTUN_TEST_COLLISIONS:-0})); then' \
  '  printf "%s\n" "$ETTUN_RETRY_MARKER" >&2' \
  'fi' \
  'if [[ -n "${ETTUN_TEST_FATAL_STATUS:-}" ]]; then' \
  '  token=${ETTUN_RETRY_MARKER#ETTUN_COLLISION:}' \
  '  token=${token%%:*}' \
  '  printf "ETTUN_FATAL:%s:%s:test-failure\n" "$token" "$ETTUN_TEST_FATAL_STATUS" >&2' \
  'fi' \
  'if [[ "${ETTUN_TEST_ECHO_ARGS:-0}" == 1 ]]; then printf "%s\n" "$@"; fi' \
  'if [[ -n "${ETTUN_TEST_BOOTSTRAP_PAYLOAD:-}" && "${ETTUN_TEST_EXIT:-0}" == 0 && "${ETTUN_TEST_COLLISIONS:-0}" == 0 && -z "${ETTUN_TEST_FATAL_STATUS:-}" ]]; then' \
  '  bootstrap_mapping=${tunnel_spec##*,}' \
  '  bootstrap_port=${bootstrap_mapping%%:*}' \
  '  "$ETTUN_TEST_PYTHON" - "$bootstrap_port" "$ETTUN_TEST_BOOTSTRAP_PAYLOAD" "$ETTUN_RETRY_MARKER" <<PY' \
  'import os' \
  'import socket' \
  'import sys' \
  'port, output, retry_marker = sys.argv[1:]' \
  'token = retry_marker.split(":")[1]' \
  '# Like ET, fall back to ::1 if a socket claimed 127.0.0.1 after the probe.' \
  'try:' \
  '    server = socket.socket()' \
  '    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)' \
  '    server.bind(("127.0.0.1", int(port)))' \
  'except OSError:' \
  '    server.close()' \
  '    server = socket.socket(socket.AF_INET6)' \
  '    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)' \
  '    server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)' \
  '    server.bind(("::1", int(port)))' \
  'server.listen(2)' \
  'server.settimeout(float(os.environ.get("ETTUN_TEST_WAIT_SECONDS", "20")))' \
  'for _ in range(4):' \
  '    connection, _ = server.accept()' \
  '    connection.sendall(b"ETTUN_BOOTSTRAP\\n")' \
  '    received = b""' \
  '    while True:' \
  '        chunk = connection.recv(65536)' \
  '        if not chunk:' \
  '            break' \
  '        received += chunk' \
  '    if received.startswith(b"ETTUN_PAYLOAD:"):' \
  '        with open(output, "wb") as payload_file:' \
  '            payload_file.write(received)' \
  '        connection.close()' \
  '        break' \
  '    connection.close()' \
  'server.close()' \
  'PY' \
  'fi' \
  'exit "${ETTUN_TEST_EXIT:-0}"'
_write_stub "$bin/test-transport" \
  'printf "transport\n" >>"$ETTUN_TEST_LOG"' \
  'for arg in "$@"; do printf "<%s>\n" "$arg" >>"$ETTUN_TEST_LOG"; done' \
  'printf "%s\n" "$3" >"$ETTUN_TEST_REMOTE_COMMAND"' \
  'printf "%s\n" "--" >>"$ETTUN_TEST_LOG"'
_write_stub "$bin/v2-transport" \
  'if [[ ${1:-} == --ettun-capabilities ]]; then' \
  '  printf "capability-query\n" >>"$ETTUN_TEST_LOG"' \
  '  printf "connect-v2\n"' \
  '  exit 0' \
  'fi' \
  'printf "transport-v2\n" >>"$ETTUN_TEST_LOG"' \
  'for arg in "$@"; do printf "<%s>\n" "$arg" >>"$ETTUN_TEST_LOG"; done' \
  'printf "%s\n" "$5" >"$ETTUN_TEST_REMOTE_COMMAND"' \
  'printf "%s\n" "--" >>"$ETTUN_TEST_LOG"'
_write_stub "$bin/single-invocation-transport" \
  'if [[ ${1:-} == --ettun-capabilities ]]; then' \
  '  printf "%s\n" connect-v2 single-invocation-v1' \
  '  exit 0' \
  'fi' \
  'printf "single-invocation\n" >>"$ETTUN_TEST_LOG"' \
  'printf "%s\n" "$ETTUN_RETRY_MARKER" >&2' \
  'exit 75'
# Control-side helper for the losing-transport stub. "handshake" binds the
# control port the way ET binds localhost (127.0.0.1 and ::1, keeping
# whichever succeeds), records the bound families, and completes ettun's
# control handshake. With "time-wait" it first leaves an outgoing TIME-WAIT
# on 127.0.0.1:PORT, modeling a socket that claimed the port after ettun's
# probe but before the transport bound it. Exit 4 means host traffic already
# held a port the scenario needed, so the caller retries with fresh ports.
losing_helper="$tmp/losing-transport.py"
cat >"$losing_helper" <<'PY'
import errno
import os
import select
import socket
import sys

_, port, token, state, mode = sys.argv
port = int(port)


def record(line):
    with open(state, "a", encoding="utf-8") as output:
        output.write(line + "\n")


if mode == "time-wait":
    peer = socket.socket()
    peer.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    peer.bind(("127.0.0.1", 0))
    peer.listen(1)
    client = socket.socket()
    try:
        client.bind(("127.0.0.1", port))
    except OSError as error:
        if error.errno == errno.EADDRINUSE:
            sys.exit(4)
        raise
    client.connect(peer.getsockname())
    accepted, _ = peer.accept()
    client.close()
    accepted.settimeout(float(os.environ.get("ETTUN_TEST_WAIT_SECONDS", "20")))
    accepted.recv(1)
    accepted.close()
    peer.close()
if mode == "early-close":
    # A transport listener without SO_REUSEADDR that closes ettun's first
    # control connection itself, leaving its own TIME-WAIT on the port.
    listener = socket.socket()
    try:
        listener.bind(("127.0.0.1", port))
    except OSError as error:
        if error.errno == errno.EADDRINUSE:
            sys.exit(4)
        raise
    listener.listen(1)
    listener.settimeout(float(os.environ.get("ETTUN_TEST_WAIT_SECONDS", "20")))
    connection, _ = listener.accept()
    listener.close()
    connection.close()
    record("closed")
    sys.exit(0)
listeners = []
for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
    try:
        listener = socket.socket(family)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        if family == socket.AF_INET6:
            listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        listener.bind((host, port))
        listener.listen(1)
    except OSError as error:
        listener.close()
        # The ::1 case needs ET's other family available on this port.
        if (mode == "time-wait" and family == socket.AF_INET6
                and error.errno == errno.EADDRINUSE):
            sys.exit(4)
        continue
    listeners.append(listener)
    record(f"bound {host}")
if not listeners:
    sys.exit(1)
ready, _, _ = select.select(listeners, [], [], float(os.environ.get("ETTUN_TEST_WAIT_SECONDS", "20")))
if not ready:
    sys.exit(1)
connection, _ = ready[0].accept()
for listener in listeners:
    listener.close()
connection.settimeout(float(os.environ.get("ETTUN_TEST_WAIT_SECONDS", "20")))
reader = connection.makefile("rb")
connection.sendall(b"ETTUN_CONTROL\n")
if reader.readline() != f"{token}\n".encode():
    sys.exit(1)
connection.sendall(f"ETTUN_ATTACHED:{token}\n".encode())
if reader.readline() != f"ETTUN_CONFIRM:{token}\n".encode():
    sys.exit(1)
connection.sendall(f"ETTUN_CONFIRMED:{token}\n".encode())
record("attached")
PY
printf -v losing_helper_q '%q' "$losing_helper"
# Models a local socket claiming a port after ettun probed it but before the
# transport's listener bound it. The first invocation asks the test's occupier
# to take its control or local data port, then fails as a bind failure would
# (or exits with ETTUN_TEST_OCCUPY_EXIT). Role "attached" first completes the
# control handshake, so the port is lost only after a real session attached.
# Role "et" leaves a TIME-WAIT on 127.0.0.1 and then, like ET, serves the
# handshake on ::1 and exits successfully. Role "linger" only publishes its
# control port, for a socket-table stub to list as a leftover connection.
# Role "early-close" accepts ettun's first control connection on a listener
# without SO_REUSEADDR, closes it first, and fails.
_write_stub "$bin/losing-transport" \
  "losing_helper=$losing_helper_q" \
  'printf "losing\n" >>"$ETTUN_TEST_LOG"' \
  'printf "<%s>\n" "$2" >>"$ETTUN_TEST_LOG"' \
  'count=0' \
  '[[ -r "$ETTUN_TEST_COUNT" ]] && read -r count <"$ETTUN_TEST_COUNT"' \
  'count=$((count + 1))' \
  'printf "%s\n" "$count" >"$ETTUN_TEST_COUNT"' \
  'if ((count == 1)) && [[ -n "${ETTUN_TEST_OCCUPY_ROLE:-}" ]]; then' \
  '  mapping=$2' \
  '  control_mapping=${mapping##*,}' \
  '  case $ETTUN_TEST_OCCUPY_ROLE in' \
  '    control | attached | et | linger | early-close) port=${control_mapping%%:*} ;;' \
  '    local) port=${mapping%%:*} ;;' \
  '  esac' \
  '  token=${ETTUN_RETRY_MARKER#ETTUN_COLLISION:}' \
  '  token=${token%%:*}' \
  '  case $ETTUN_TEST_OCCUPY_ROLE in' \
  '    attached | et | early-close)' \
  '      helper_mode=plain' \
  '      [[ $ETTUN_TEST_OCCUPY_ROLE != et ]] || helper_mode=time-wait' \
  '      [[ $ETTUN_TEST_OCCUPY_ROLE != early-close ]] || helper_mode=early-close' \
  '      helper_status=0' \
  '      "$ETTUN_TEST_PYTHON" "$losing_helper" "$port" "$token" "$ETTUN_TEST_OCCUPY_STATE" "$helper_mode" || helper_status=$?' \
  '      if ((helper_status == 4)); then' \
  '        printf "losing-transport: precondition missed on port %s\\n" "$port" >&2' \
  '        exit 98' \
  '      fi' \
  '      ((helper_status == 0)) || exit 1' \
  '      [[ $ETTUN_TEST_OCCUPY_ROLE != et ]] || exit 0' \
  '      [[ $ETTUN_TEST_OCCUPY_ROLE != early-close ]] || exit 1' \
  '      ;;' \
  '  esac' \
  '  printf "%s\n" "$port" >"$ETTUN_TEST_OCCUPY_REQUEST.tmp"' \
  '  mv "$ETTUN_TEST_OCCUPY_REQUEST.tmp" "$ETTUN_TEST_OCCUPY_REQUEST"' \
  '  [[ $ETTUN_TEST_OCCUPY_ROLE != linger ]] || exit 1' \
  '  # Wait as long as the occupier waits for this request.' \
  '  ack_wait=$((SECONDS + 3 * ${ETTUN_TEST_WAIT_SECONDS:-20}))' \
  '  while ((SECONDS < ack_wait)); do' \
  '    [[ -e "$ETTUN_TEST_OCCUPY_ACK" || -e "$ETTUN_TEST_OCCUPY_ACK.failed" ]] && break' \
  '    sleep 0.05' \
  '  done' \
  '  if [[ -e "$ETTUN_TEST_OCCUPY_ACK.failed" ]]; then' \
  '    printf "losing-transport: precondition missed on port %s\\n" "$port" >&2' \
  '    exit 98' \
  '  fi' \
  '  if [[ ! -e "$ETTUN_TEST_OCCUPY_ACK" ]]; then' \
  '    printf "losing-transport: occupier never confirmed port %s\n" "$port" >&2' \
  '    exit 97' \
  '  fi' \
  '  printf "bind 127.0.0.1:%s: Address already in use\n" "$port" >&2' \
  '  exit "${ETTUN_TEST_OCCUPY_EXIT:-1}"' \
  'fi' \
  'exit "${ETTUN_TEST_EXIT:-0}"'
_write_stub "$bin/blocking-transport" \
  'printf "%s\n" "$$" >"$ETTUN_TEST_TRANSPORT_PID"' \
  'sleep 300 &' \
  'child=$!' \
  'printf "%s\n" "$child" >"$ETTUN_TEST_TRANSPORT_CHILD_PID"' \
  'wait "$child"'
_write_stub "$bin/interactive-transport" \
  'printf "%s\n" "$$" >"$ETTUN_TEST_TRANSPORT_PID"' \
  'trap "" INT' \
  '[[ -z "${ETTUN_TEST_TRANSPORT_COUNT:-}" ]] || printf "1\n" >>"$ETTUN_TEST_TRANSPORT_COUNT"' \
  'if [[ -n "${ETTUN_TEST_RESUME_MARKER:-}" ]]; then' \
  '  resume_ready="$ETTUN_TEST_RESUME_MARKER.ready"' \
  '  resume_pid_file="$ETTUN_TEST_RESUME_MARKER.pid"' \
  '  rm -f "$resume_ready" "$resume_pid_file" "$ETTUN_TEST_RESUME_MARKER"' \
  '  "$ETTUN_TEST_PYTHON" - "$resume_ready" "$ETTUN_TEST_RESUME_MARKER" <<PY >/dev/null 2>&1 &' \
  'import signal' \
  'import sys' \
  'def mark_resumed(_signum, _frame):' \
  '    open(sys.argv[2], "wb").close()' \
  'signal.signal(signal.SIGCONT, mark_resumed)' \
  'open(sys.argv[1], "wb").close()' \
  'while True:' \
  '    signal.pause()' \
  'PY' \
  '  resume_observer=$!' \
  '  printf "%s\n" "$resume_observer" >"$resume_pid_file"' \
  '  # Stay alive to avoid SIGCHLD during read; group cleanup is asserted by the test.' \
  '  resume_wait=$((SECONDS + ${ETTUN_TEST_WAIT_SECONDS:-20}))' \
  '  while [[ ! -e "$resume_ready" ]] && ((SECONDS < resume_wait)); do sleep 0.1; done' \
  '  if [[ ! -e "$resume_ready" ]]; then' \
  '    printf "resume observer did not become ready\n" >&2' \
  '    kill "$resume_observer" 2>/dev/null || true' \
  '    exit 1' \
  '  fi' \
  'fi' \
  'ps -o pid=,pgid=,tpgid=,stat= -p "$$" >"$ETTUN_TEST_AUTH_STATE"' \
  'printf "Passcode: "' \
  'IFS= read -r answer' \
  'printf "%s\n" "$answer" >"$ETTUN_TEST_AUTH_RESULT"' \
  'exec sleep 300'
_write_stub "$bin/interactive-attached-transport" \
  'printf "%s\n" "$$" >"$ETTUN_TEST_TRANSPORT_PID"' \
  'printf "Passcode: "' \
  'if [[ -n "${ETTUN_TEST_PREAUTH_STOPPED:-}" ]]; then' \
  '  : >"$ETTUN_TEST_PREAUTH_STOPPED"' \
  '  kill -TTIN 0' \
  'fi' \
  'IFS= read -r answer' \
  'printf "%s\n" "$answer" >"$ETTUN_TEST_AUTH_RESULT"' \
  'mapping=$2' \
  'control_mapping=${mapping#*,}' \
  'control_port=${control_mapping%%:*}' \
  'token=${ETTUN_RETRY_MARKER#ETTUN_COLLISION:}' \
  'token=${token%%:*}' \
  'exec python3 - "$control_port" "$token" <<PY' \
  'import os' \
  'import signal' \
  'import socket' \
  'import sys' \
  'import time' \
  'resume_count = 0' \
  'def mark_resumed(_signum, _frame):' \
  '    global resume_count' \
  '    resume_count += 1' \
  '    with open(os.environ["ETTUN_TEST_CONTROL_RESUMED"], "w", encoding="utf-8") as output:' \
  '        output.write(str(resume_count))' \
  '    if resume_count <= 3 and os.environ.get("ETTUN_TEST_RESTOP_AFTER_CONT") == "1":' \
  '        os.killpg(os.getpgrp(), signal.SIGSTOP)' \
  'signal.signal(signal.SIGINT, lambda _signum, _frame: sys.exit(130))' \
  'signal.signal(signal.SIGCONT, signal.SIG_DFL)' \
  'signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGINT, signal.SIGCONT})' \
  '# Like ET, fall back to ::1 if a socket claimed 127.0.0.1 after the probe.' \
  'try:' \
  '    server = socket.socket()' \
  '    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)' \
  '    server.bind(("127.0.0.1", int(sys.argv[1])))' \
  'except OSError:' \
  '    server.close()' \
  '    server = socket.socket(socket.AF_INET6)' \
  '    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)' \
  '    server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)' \
  '    server.bind(("::1", int(sys.argv[1])))' \
  'server.listen(1)' \
  'open(os.environ["ETTUN_TEST_CONTROL_READY"], "wb").close()' \
  'connection, _ = server.accept()' \
  'connection.sendall(b"ETTUN_CONTROL\\n")' \
  'received = b""' \
  'with connection:' \
  '    while b"\\n" not in received:' \
  '        chunk = connection.recv(256)' \
  '        if not chunk:' \
  '            break' \
  '        received += chunk' \
  '    with open(os.environ["ETTUN_TEST_CONTROL_TOKEN"], "wb") as output:' \
  '        output.write(received)' \
  '    expected_token = f"{sys.argv[2]}\\n".encode()' \
  '    if received != expected_token:' \
  '        raise RuntimeError(f"unexpected token: {received!r}")' \
  '    time.sleep(float(os.environ.get("ETTUN_TEST_ACK_DELAY", "0")))' \
  '    connection.sendall(f"ETTUN_ATTACHED:{sys.argv[2]}\\n".encode())' \
  '    confirm = b""' \
  '    while b"\\n" not in confirm:' \
  '        chunk = connection.recv(256)' \
  '        if not chunk:' \
  '            break' \
  '        confirm += chunk' \
  '    expected = f"ETTUN_CONFIRM:{sys.argv[2]}\\n".encode()' \
  '    if confirm != expected:' \
  '        raise RuntimeError(f"unexpected confirmation: {confirm!r}")' \
  '    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGCONT})' \
  '    signal.signal(signal.SIGCONT, mark_resumed)' \
  '    connection.sendall(f"ETTUN_CONFIRMED:{sys.argv[2]}\\n".encode())' \
  '    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGCONT})' \
  '    resume_deadline = time.monotonic() + float(os.environ.get("ETTUN_TEST_WAIT_SECONDS", "20"))' \
  '    resumed = os.environ["ETTUN_TEST_CONTROL_RESUMED"]' \
  '    while not os.path.exists(resumed) and time.monotonic() < resume_deadline:' \
  '        time.sleep(0.01)' \
  '    if not os.path.exists(resumed):' \
  '        raise TimeoutError("transport did not resume after control handoff")' \
  '    connection.sendall(b"ETTUN_HELD\\n")' \
  '    open(os.environ["ETTUN_TEST_CONTROL_HELD"], "wb").close()' \
  '    try:' \
  '        while connection.recv(256):' \
  '            pass' \
  '    except ConnectionResetError:' \
  '        pass' \
  'open(os.environ["ETTUN_TEST_CONTROL_EOF"], "wb").close()' \
  'server.close()' \
  'PY'
_write_stub "$bin/worker-pgrp-transport" \
  'worker_pgid=$(ps -o pgid= -p "$PPID" | tr -d " ")' \
  'adapter_pgid=$(ps -o pgid= -p "$$" | tr -d " ")' \
  'printf "%s %s\n" "$worker_pgid" "$adapter_pgid" >"$ETTUN_TEST_WORKER_PGRPS"'
_write_stub "$bin/tstp-exit-transport" \
  'kill -TSTP 0' \
  'exit 127'
_write_stub "$bin/exit-127-transport" \
  'exit 127'
_write_stub "$bin/delayed-control-transport" \
  'printf "%s\n" "$$" >"$ETTUN_TEST_TRANSPORT_PID"' \
  'mapping=$2' \
  'control_mapping=${mapping#*,}' \
  'control_port=${control_mapping%%:*}' \
  'token=${ETTUN_RETRY_MARKER#ETTUN_COLLISION:}' \
  'token=${token%%:*}' \
  'sleep 1' \
  'python3 - "$control_port" "$ETTUN_TEST_CONTROL_TOKEN" "${ETTUN_TEST_CONTROL_READY:-}" "$token" "${ETTUN_TEST_CONTROL_ATTACHED:-}" "${ETTUN_TEST_CONTROL_EOF:-}" <<PY' \
  'import socket' \
  'import signal' \
  'import sys' \
  'signal.signal(signal.SIGINT, lambda _signum, _frame: sys.exit(130))' \
  'signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGINT})' \
  '# Like ET, fall back to ::1 if a socket claimed 127.0.0.1 after the probe.' \
  'try:' \
  '    server = socket.socket()' \
  '    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)' \
  '    server.bind(("127.0.0.1", int(sys.argv[1])))' \
  'except OSError:' \
  '    server.close()' \
  '    server = socket.socket(socket.AF_INET6)' \
  '    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)' \
  '    server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)' \
  '    server.bind(("::1", int(sys.argv[1])))' \
  'server.listen(1)' \
  'if sys.argv[3]:' \
  '    open(sys.argv[3], "wb").close()' \
  'expected_stop = f"ETTUN_STOP:{sys.argv[4]}\n".encode()' \
  'expected_attach = f"{sys.argv[4]}\n".encode()' \
  '# Without an attach marker the case expects a stop request. Under load the' \
  '# control helper can still attach before the signal lands; turn it away' \
  '# and keep listening rather than record that race as the result.' \
  'while True:' \
  '    connection, _ = server.accept()' \
  '    connection.sendall(b"ETTUN_CONTROL\\n")' \
  '    received = b""' \
  '    while b"\n" not in received:' \
  '        chunk = connection.recv(256)' \
  '        if not chunk:' \
  '            break' \
  '        received += chunk' \
  '    if received == expected_attach and not sys.argv[5]:' \
  '        connection.close()' \
  '        continue' \
  '    break' \
  'with connection:' \
  '    with open(sys.argv[2], "wb") as output:' \
  '        output.write(received)' \
  '    if received == expected_stop:' \
  '        connection.sendall(f"ETTUN_STOPPED:{sys.argv[4]}\n".encode())' \
  '    elif received == expected_attach:' \
  '        connection.sendall(f"ETTUN_ATTACHED:{sys.argv[4]}\n".encode())' \
  '        confirm = b""' \
  '        while b"\n" not in confirm:' \
  '            chunk = connection.recv(256)' \
  '            if not chunk:' \
  '                break' \
  '            confirm += chunk' \
  '        expected_confirm = f"ETTUN_CONFIRM:{sys.argv[4]}\n".encode()' \
  '        if confirm == expected_confirm:' \
  '            connection.sendall(f"ETTUN_CONFIRMED:{sys.argv[4]}\n".encode())' \
  '            if sys.argv[5]:' \
  '                open(sys.argv[5], "wb").close()' \
  '    try:' \
  '        while connection.recv(256):' \
  '            pass' \
  '    except ConnectionResetError:' \
  '        pass' \
  'if sys.argv[6]:' \
  '    open(sys.argv[6], "wb").close()' \
  'server.close()' \
  'PY'
_write_stub "$bin/dropping-control-transport" \
  'printf "%s\n" "$$" >"$ETTUN_TEST_TRANSPORT_PID"' \
  'mapping=$2' \
  'control_mapping=${mapping#*,}' \
  'control_port=${control_mapping%%:*}' \
  'token=${ETTUN_RETRY_MARKER#ETTUN_COLLISION:}' \
  'token=${token%%:*}' \
  'python3 - "$control_port" "$token" <<PY' \
  'import os' \
  'import socket' \
  'import time' \
  'import sys' \
  '# Like ET, fall back to ::1 if a socket claimed 127.0.0.1 after the probe.' \
  'try:' \
  '    server = socket.socket()' \
  '    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)' \
  '    server.bind(("127.0.0.1", int(sys.argv[1])))' \
  'except OSError:' \
  '    server.close()' \
  '    server = socket.socket(socket.AF_INET6)' \
  '    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)' \
  '    server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)' \
  '    server.bind(("::1", int(sys.argv[1])))' \
  'server.listen(4)' \
  'open(os.environ["ETTUN_TEST_CONTROL_READY"], "wb").close()' \
  'while not os.path.exists(os.environ["ETTUN_TEST_CONTROL_GATE"]):' \
  '    time.sleep(0.05)' \
  'expected_stop = f"ETTUN_STOP:{sys.argv[2]}\n".encode()' \
  'dropped_stop = False' \
  'while True:' \
  '    connection, _ = server.accept()' \
  '    connection.sendall(b"ETTUN_CONTROL\\n")' \
  '    received = b""' \
  '    with connection:' \
  '        while b"\n" not in received:' \
  '            chunk = connection.recv(256)' \
  '            if not chunk:' \
  '                break' \
  '            received += chunk' \
  '        if received != expected_stop:' \
  '            continue' \
  '        if not dropped_stop:' \
  '            open(os.environ["ETTUN_TEST_CONTROL_DROPPED"], "wb").close()' \
  '            dropped_stop = True' \
  '            continue' \
  '        with open(os.environ["ETTUN_TEST_CONTROL_TOKEN"], "wb") as output:' \
  '            output.write(received)' \
  '        connection.sendall(f"ETTUN_STOPPED:{sys.argv[2]}\n".encode())' \
  '        while connection.recv(256):' \
  '            pass' \
  '        break' \
  'server.close()' \
  'PY'

_decode_remote_payload() {
  local wire="$1" magic token payload

  IFS=: read -r magic token payload <<<"$wire"
  [[ "$magic" == ETTUN_PAYLOAD && "$token" =~ ^[0-9a-f]{32}$ ]] || return 1
  if printf '%s' "$payload" | base64 -d 2>/dev/null | gzip -dc 2>/dev/null; then
    return
  fi
  printf '%s' "$payload" | base64 -D 2>/dev/null | gzip -dc
}

_run_ettun() {
  : >"$log"
  stdout="$tmp/stdout"
  stderr="$tmp/stderr"
  count="$tmp/count"
  remote_command_file="$tmp/remote-command"
  bootstrap_payload_file="$tmp/bootstrap-payload"
  run_exit=0
  : >"$count"
  : >"$remote_command_file"
  rm -f "$bootstrap_payload_file"
  rm -f "$port_probe_error"
  PATH="${ETTUN_TEST_PATH:-$bin:$test_system_path}" \
    HOME="$test_home" \
    XDG_STATE_HOME="$test_home/state" \
    ETTUN_TEST_LOG="$log" \
    ETTUN_TEST_REMOTE_COMMAND="$remote_command_file" \
    ETTUN_TEST_BOOTSTRAP_PAYLOAD="$bootstrap_payload_file" \
    ETTUN_TEST_PYTHON="$test_python" \
    ETTUN_TEST_PORT_PROBE_ERROR="$port_probe_error" \
    ETTUN_TEST_COUNT="$count" \
    ETTUN_TEST_COLLISIONS="${ETTUN_TEST_COLLISIONS:-0}" \
    ETTUN_TEST_EXIT="${ETTUN_TEST_EXIT:-0}" \
    ETTUN_TEST_FATAL_STATUS="${ETTUN_TEST_FATAL_STATUS:-}" \
    ETTUN_TEST_ECHO_ARGS="${ETTUN_TEST_ECHO_ARGS:-0}" \
    ETTUN_CLIENT_ID="${ETTUN_TEST_CLIENT_ID-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
    ETTUN_TEST_LSOF_EXIT="${ETTUN_TEST_LSOF_EXIT:-}" \
    ETTUN_TEST_LSOF_ESTABLISHED_PORT="${ETTUN_TEST_LSOF_ESTABLISHED_PORT:-}" \
    ETTUN_TEST_LSOF_REMOTE_PORT="${ETTUN_TEST_LSOF_REMOTE_PORT:-}" \
    ETTUN_TEST_SS_LISTENER_PORT="${ETTUN_TEST_SS_LISTENER_PORT:-}" \
    ETTUN_ET="${ETTUN_TEST_ET:-et}" \
    ETTUN_TRANSPORT="${ETTUN_TEST_TRANSPORT:-}" \
    bash "$SCRIPT" "$@" >"$stdout" 2>"$stderr" || run_exit=$?
  if [[ -s "$port_probe_error" ]]; then
    printf 'fixture port probe failed:\n' >>"$stderr"
    cat "$port_probe_error" >>"$stderr"
    run_exit=1
    _fail "fixture: local port availability probe failed"
    return 1
  fi
}

_wait_for_file() {
  local path="$1" deadline=$((SECONDS + WAIT_DEADLINE_SECONDS))
  while :; do
    [[ -s "$path" ]] && return
    ((SECONDS < deadline)) || return 1
    sleep 0.1
  done
}

_wait_for_marker() {
  local path="$1" deadline=$((SECONDS + WAIT_DEADLINE_SECONDS))
  while :; do
    [[ -e "$path" ]] && return
    ((SECONDS < deadline)) || return 1
    sleep 0.1
  done
}

# Every transport worker a suite starts carries a runtime directory beneath
# this suite's private temporary root in its argv, which proves ownership.
# Give exiting workers the usual bound, then kill and report any survivor so
# a cleanup gap fails the suite instead of leaving orphans on the host.
_leaked_workers() {
  local pid args

  while read -r pid args; do
    [[ $pid =~ ^[0-9]+$ && $args == *--ettun-transport-worker*"$tmp/"* ]] &&
      printf '%s\n' "$pid"
  done < <("$real_ps" -axo pid=,args= 2>/dev/null)
}

_assert_no_leaked_workers() {
  local pid deadline=$((SECONDS + WAIT_DEADLINE_SECONDS))
  local -a leaked

  while :; do
    leaked=()
    while read -r pid; do
      leaked+=("$pid")
    done < <(_leaked_workers)
    ((${#leaked[@]} == 0)) && break
    ((SECONDS < deadline)) || break
    sleep 0.1
  done
  if ((${#leaked[@]} == 0)); then
    _pass "suite cleanup: no transport worker survives"
    return
  fi
  for pid in "${leaked[@]}"; do
    # A worker started under job control leads its own process group.
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
  _fail "suite cleanup: no transport worker survives (killed ${leaked[*]})"
}

_process_has_stopped() {
  local pid="$1" state

  state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
  [[ -z "$state" || "$state" == *Z* ]]
}

_wait_for_processes_stopped() {
  local pid all_stopped deadline=$((SECONDS + WAIT_DEADLINE_SECONDS))

  while :; do
    all_stopped=1
    for pid in "$@"; do
      if ! _process_has_stopped "$pid"; then
        all_stopped=0
      fi
    done
    ((all_stopped == 1)) && return
    ((SECONDS < deadline)) || return 1
    sleep 0.1
  done
}
