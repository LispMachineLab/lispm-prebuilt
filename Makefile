# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
#
#   make test      the tests: a package of their own, downloaded from file: URLs
#   make compile   byte-compile the Emacs Lisp, warnings failing it

EMACS ?= emacs
EMACS_BATCH = $(EMACS) -Q --batch -L .

.PHONY: all test compile

all: compile test

test:
	$(EMACS_BATCH) -L test -l test/lispm-prebuilt-test.el -f ert-run-tests-batch-and-exit

compile:
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile \
	  lispm-prebuilt.el test/lispm-prebuilt-test.el
	/bin/rm -f *.elc test/*.elc
