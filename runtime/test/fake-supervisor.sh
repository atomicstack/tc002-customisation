#!/bin/sh
# stands in for tc002-supervisor in the host dlopen test: succeeds only when exec'd the way the
# bootstrap does it (argv[1] = --from-bootstrap, the environment passed through).
[ "$1" = "--from-bootstrap" ] || exit 3
[ "$TC002_TEST_ENV" = "passed-through" ] || exit 4
exit 0
