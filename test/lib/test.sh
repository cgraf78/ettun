#!/usr/bin/env bash
# Minimal test harness shared by ettun's behavior suites.

set -uo pipefail

PASS=0
FAIL=0

_pass() {
  PASS=$((PASS + 1))
  printf '  PASS: %s\n' "$1"
}

_fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL: %s\n' "$1" >&2
}

_assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    _pass "$description"
  else
    _fail "$description (expected '$expected', got '$actual')"
  fi
}

_assert_contains() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    _pass "$description"
  else
    _fail "$description (expected to contain '$expected', got '$actual')"
  fi
}

_assert_not_contains() {
  local description="$1" unexpected="$2" actual="$3"
  if [[ "$actual" != *"$unexpected"* ]]; then
    _pass "$description"
  else
    _fail "$description (should not contain '$unexpected')"
  fi
}

_assert_exit() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" -eq "$actual" ]]; then
    _pass "$description"
  else
    _fail "$description (expected exit $expected, got $actual)"
  fi
}

_assert_file_exists() {
  local description="$1" path="$2"
  if [[ -f "$path" ]]; then
    _pass "$description"
  else
    _fail "$description (file not found: $path)"
  fi
}

_assert_file_content() {
  local description="$1" expected="$2" path="$3" actual
  if [[ ! -f "$path" ]]; then
    _fail "$description (file not found: $path)"
    return
  fi

  actual=$(<"$path")
  if [[ "$actual" == "$expected" ]]; then
    _pass "$description"
  else
    _fail "$description (expected content '$expected', got '$actual')"
  fi
}

_ETTUN_TEST_TMP_BASE=${TMPDIR:-/tmp}
_ETTUN_TEST_TMP_ROOT=$(mktemp -d "$_ETTUN_TEST_TMP_BASE/ettun-test.XXXXXXXX") || {
  printf 'test harness: could not create temporary root\n' >&2
  exit 1
}
case "$_ETTUN_TEST_TMP_ROOT" in
  "$_ETTUN_TEST_TMP_BASE"/ettun-test.*) ;;
  *)
    printf 'test harness: unsafe temporary root: %s\n' "$_ETTUN_TEST_TMP_ROOT" >&2
    exit 1
    ;;
esac

_tmpdir() {
  local suite_tmp

  suite_tmp=$(mktemp -d "$_ETTUN_TEST_TMP_ROOT/suite.XXXXXXXX") || {
    printf 'test harness: could not create suite temporary directory\n' >&2
    return 1
  }
  case "$suite_tmp" in
    "$_ETTUN_TEST_TMP_ROOT"/suite.*) ;;
    *)
      printf 'test harness: unsafe suite temporary directory: %s\n' \
        "$suite_tmp" >&2
      return 1
      ;;
  esac
  if [[ ! -d "$suite_tmp" ]]; then
    printf 'test harness: suite temporary directory does not exist: %s\n' \
      "$suite_tmp" >&2
    return 1
  fi
  printf '%s\n' "$suite_tmp"
}

_cleanup_test_root() {
  local status=$?
  trap - EXIT
  case "$_ETTUN_TEST_TMP_ROOT" in
    "$_ETTUN_TEST_TMP_BASE"/ettun-test.*) rm -rf -- "$_ETTUN_TEST_TMP_ROOT" ;;
  esac
  exit "$status"
}
trap _cleanup_test_root EXIT

_test_summary() {
  printf '\n================================\n'
  printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
  printf '================================\n'
  if ((FAIL == 0)); then
    exit 0
  fi
  exit 1
}
