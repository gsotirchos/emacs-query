#!/usr/bin/env bash
# End-to-end checks for the emacs-query command, including argument parsing,
# the stdin payload path, exit codes and the reusable daemon.
set -euo pipefail

repo="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${repo}/bin:${PATH}"

failures=0
checks=0

# Assert that running emacs-query with the given arguments exits with the
# expected status and prints something matching the expected pattern.
expect() {
    local label="$1" pattern="$2" want_status="$3"
    shift 3
    local output status=0
    checks=$((checks + 1))
    output="$(emacs-query "$@" 2>&1)" || status=$?

    if [[ "${status}" -ne "${want_status}" ]]; then
        printf 'FAIL %-34s exit %s, wanted %s\n' "${label}" "${status}" "${want_status}"
        failures=$((failures + 1))
        return
    fi
    if [[ -n "${pattern}" ]] && ! grep -qE "${pattern}" <<< "${output}"; then
        printf 'FAIL %-34s no match for %s\n' "${label}" "${pattern}"
        printf '     got: %s\n' "$(head -3 <<< "${output}")"
        failures=$((failures + 1))
        return
    fi
    printf 'ok   %s\n' "${label}"
}

# stdout must carry the report and nothing else, so an agent can pipe it.
expect_clean_stderr() {
    local label="$1"
    shift
    local err
    checks=$((checks + 1))
    err="$(emacs-query "$@" 2>&1 > /dev/null)" || true
    if [[ -n "${err}" ]]; then
        printf 'FAIL %-34s stderr not empty: %s\n' "${label}" "$(head -2 <<< "${err}")"
        failures=$((failures + 1))
    else
        printf 'ok   %s\n' "${label}"
    fi
}

echo "== fast tier =="
expect "describe core function" '^## (Command|Function): save-buffer' 0 \
    describe save-buffer
expect "describe gives file:line" 'Defined in: .*files\.el:[0-9]+' 0 \
    describe save-buffer
expect "describe keeps &optional" 'Signature: \(save-buffer &optional ARG\)' 0 \
    describe save-buffer
expect "describe variable" '^## Variable: fill-column' 0 describe fill-column
expect "describe face" '^## Face: mode-line' 0 describe mode-line
expect "describe flags obsolete" 'OBSOLETE' 0 describe if-let
expect "apropos labels matches" 'save-buffer --' 0 apropos '\`save-buffer'
expect "library finds core lib" 'subr-x\.el' 0 library subr-x
expect "macroexpand expands" '\(if a \(progn b\)\)' 0 macroexpand '(when a b)'
expect "eval prints value" '^3$' 0 eval '(+ 1 2)'
expect "info reads the manual" 'Mapping Functions' 0 info mapconcat
expect "keys resolves a sequence" 'Runs: save-buffer' 0 keys 'C-x C-s'
expect "keys resolves a command" 'C-x C-s' 0 keys save-buffer
expect_clean_stderr "stderr clean on success" describe save-buffer

echo
echo "== failure modes =="
expect "unknown symbol exits 3" 'Nothing found' 3 describe no-such-symbol-xyzzy
expect "missing argument exits 2" 'needs an argument' 2 describe
expect "unknown option exits 2" 'unknown option' 2 --bogus describe car
expect "bad --limit exits 2" 'needs a number' 2 --limit abc describe car
expect "help exits 0" 'Subcommands:' 0 --help
expect "version exits 0" '0\.[0-9]+\.[0-9]+' 0 --version

status=0
EMACS=/nonexistent emacs-query describe car > /dev/null 2>&1 || status=$?
checks=$((checks + 1))
if [[ "${status}" -eq 2 ]]; then
    printf 'ok   %s\n' "missing emacs exits 2"
else
    printf 'FAIL %-34s exit %s, wanted 2\n' "missing emacs exits 2" "${status}"
    failures=$((failures + 1))
fi

echo
echo "== stdin payload =="
checks=$((checks + 1))
if printf '(progn\n  (list 1 "two" (quote three)))\n' \
    | emacs-query eval - 2> /dev/null | grep -qF '(1 "two" three)'; then
    printf 'ok   %s\n' "multi-line sexp via stdin"
else
    printf 'FAIL %s\n' "multi-line sexp via stdin"
    failures=$((failures + 1))
fi

echo
echo "== reusable daemon =="
# Captured rather than piped: `grep -q' exits at the first match, and the
# SIGPIPE that gives the producer would trip `pipefail'.  Matched with a
# prefix pattern because the "not running" status also contains "running".
daemon_state() { emacs-query daemon status; }

if [[ "$(daemon_state)" == running* ]]; then
    echo "skip  a daemon is already running; not touching it"
else
    emacs-query daemon start > /dev/null
    checks=$((checks + 1))
    if [[ "$(daemon_state)" == running* ]]; then
        printf 'ok   %s\n' "daemon reports running"
    else
        printf 'FAIL %-34s got: %s\n' "daemon reports running" "$(daemon_state)"
        failures=$((failures + 1))
    fi

    # The daemon is a pure speed change: identical bytes on stdout.
    checks=$((checks + 1))
    via_daemon="$(emacs-query describe save-buffer 2> /dev/null)"
    emacs-query daemon stop > /dev/null
    via_batch="$(emacs-query describe save-buffer 2> /dev/null)"
    if [[ "${via_daemon}" == "${via_batch}" ]]; then
        printf 'ok   %s\n' "daemon output matches batch"
    else
        printf 'FAIL %s\n' "daemon output matches batch"
        failures=$((failures + 1))
    fi

    checks=$((checks + 1))
    if [[ "$(daemon_state)" == "not running" ]]; then
        printf 'ok   %s\n' "daemon stops cleanly"
    else
        printf 'FAIL %s\n' "daemon stops cleanly"
        failures=$((failures + 1))
    fi
fi

echo
echo "== unit tests =="
if "${EMACS:-emacs}" -Q --batch -l "${repo}/lisp/emacs-query.el" \
    -l "${repo}/test/emacs-query-test.el" \
    -f ert-run-tests-batch-and-exit > /dev/null 2>&1; then
    printf 'ok   %s\n' "ert suite"
    checks=$((checks + 1))
else
    printf 'FAIL %s\n' "ert suite"
    failures=$((failures + 1))
    checks=$((checks + 1))
fi

echo
if [[ "${failures}" -eq 0 ]]; then
    echo "${checks} checks passed"
else
    echo "${failures} of ${checks} checks failed"
    exit 1
fi
