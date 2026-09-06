#!/bin/bash
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PATH=$HERE/testdata:$PATH
export PATH

output=$("$HERE/tc002-led.sh" status)
case "$output" in
    *"stock app: running"*) ;;
    *) echo "test_wrapper: missing stock status" >&2; exit 1 ;;
esac
case "$output" in
    *"popsquares: running (pid 123)"*) ;;
    *) echo "test_wrapper: failed to recognise the owned pid" >&2; exit 1 ;;
esac

echo "test_wrapper: 2 checks, 0 failed"
