#!/bin/sh
# Run the Glasspane test suite in batch Emacs (28+).
# On this project's Windows host:  wsl -d Debian -- test/run-tests.sh
cd "$(dirname "$0")/.." || exit 1
exec emacs -Q --batch -l test/eabp-tests.el -f ert-run-tests-batch-and-exit
