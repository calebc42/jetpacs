#!/bin/sh
# Run the Glasspane test suite in batch Emacs (28+).
# On this project's Windows host:  wsl -d Debian -- test/run-tests.sh
#
# Set JETPACS_MODUS_DIR to a modus-themes >=5.0 checkout to also exercise the
# theme mirror's derivative-detection tests (they skip otherwise, since Emacs's
# bundled modus 4.x lacks the derivative registry).  The variable is read by
# jetpacs-tests.el via getenv and inherited from this shell.
cd "$(dirname "$0")/.." || exit 1
# The Jetpacs core must load with no app layer present (the tier boundary).
emacs -Q --batch -l test/core-load-test.el || exit 1
exec emacs -Q --batch -l test/jetpacs-tests.el -f ert-run-tests-batch-and-exit
