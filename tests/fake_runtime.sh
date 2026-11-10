#!/bin/sh
# Fake container CLI for tests: installed as docker, podman and container. Records "<name> <argv>"
# in $TEST_TMP/rt.log, prints $FAKE_RT_OUT_<verb> if set (verb = first argument), and exits with
# $FAKE_RT_RC_<verb>, else $FAKE_RT_RC, else 0. $FAKE_RT_RC_SEQ_<verb>, when set, names a file of
# exit codes, one per line: each call takes (and removes) the first one; once it is empty, the rules
# above apply again.
verb="$1"
echo "$(basename "$0") $*" >> "$TEST_TMP/rt.log"
eval "out=\${FAKE_RT_OUT_$verb-}"
[ -n "$out" ] && printf '%s\n' "$out"
eval "seq=\${FAKE_RT_RC_SEQ_$verb-}"
if [ -n "$seq" ] && [ -s "$seq" ]; then
    rc="$(head -n 1 "$seq")"; sed -i '1d' "$seq"
    exit "$rc"
fi
eval "rc=\${FAKE_RT_RC_$verb:-\${FAKE_RT_RC:-0}}"
exit "$rc"
