#!/bin/sh
# Fake container CLI for tests: installed as docker, podman and container. Records "<name> <argv>"
# in $TEST_TMP/rt.log, prints $FAKE_RT_OUT_<verb> if set (verb = first argument), and exits with
# $FAKE_RT_RC_<verb>, else $FAKE_RT_RC, else 0.
verb="$1"
echo "$(basename "$0") $*" >> "$TEST_TMP/rt.log"
eval "out=\${FAKE_RT_OUT_$verb-}"
[ -n "$out" ] && printf '%s\n' "$out"
eval "rc=\${FAKE_RT_RC_$verb:-\${FAKE_RT_RC:-0}}"
exit "$rc"
