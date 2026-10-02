;;; emacs-query-test.el --- Tests for emacs-query  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The README documents how to run this suite; `test/smoke.sh' also runs it.
;;
;; Every test uses core Emacs symbols only, so the suite passes without the
;; user's configuration and without network access.

;;; Code:

(require 'ert)
(require 'emacs-query)

;;;; Formatting

(ert-deftest emacs-query-test-first-line ()
  (should (equal (emacs-query--first-line "one\ntwo") "one"))
  (should (equal (emacs-query--first-line nil) "")))

(ert-deftest emacs-query-test-section-skips-empty ()
  (should-not (emacs-query--section "Title" ""))
  (should-not (emacs-query--section "Title" nil))
  (should (equal (emacs-query--section "Title" "body") "## Title\n\nbody\n")))

(ert-deftest emacs-query-test-capped ()
  (let* ((emacs-query-limit 2)
         (capped (emacs-query--capped '(a b c d))))
    (should (equal (car capped) '(a b)))
    (should (string-match-p "2 more of 4" (cdr capped))))
  (let ((capped (emacs-query--capped '(a))))
    (should (equal (car capped) '(a)))
    (should-not (cdr capped))))

(ert-deftest emacs-query-test-truncate ()
  (let ((emacs-query-max-lines 2))
    (should (string-match-p "1 more line" (emacs-query--truncate "a\nb\nc")))
    (should (equal (emacs-query--truncate "a\nb") "a\nb"))))

(ert-deftest emacs-query-test-pp-is-bounded ()
  "A huge value must stay printable rather than flood the report."
  (let ((emacs-query-print-length 3)
        (emacs-query-print-level 2))
    (should (string-match-p "\\.\\.\\." (emacs-query--pp (number-sequence 1 100))))))

;;;; Symbol classification

(ert-deftest emacs-query-test-function-kind ()
  "Regression test for the `subrp' trap.
A native-compiled Lisp function satisfies `subrp', so classifying by it
would label most of Emacs \"built-in\"."
  (should (equal (emacs-query--function-kind 'car) "Built-in function"))
  (should (equal (emacs-query--function-kind 'when) "Macro"))
  (should (equal (emacs-query--function-kind 'if) "Special form"))
  (should (equal (emacs-query--function-kind 'save-buffer) "Command"))
  (should-not (subr-primitive-p (symbol-function 'save-buffer))))

(ert-deftest emacs-query-test-locate ()
  (should (string-match-p "files\\.el:[0-9]+\\'"
                          (emacs-query--locate
                           'save-buffer (symbol-function 'save-buffer))))
  (should (string-match-p "C source"
                          (emacs-query--locate
                           'car (symbol-function 'car)))))

(ert-deftest emacs-query-test-obsolete-note ()
  (should-not (emacs-query--obsolete-note 'car))
  (let ((note (emacs-query--obsolete-note 'if-let)))
    (should (and note (string-prefix-p "OBSOLETE" note)))))

(ert-deftest emacs-query-test-signature-keeps-ampersand-lowercase ()
  "`&optional' is not an argument name and must not be upcased."
  ;; `case-fold-search' defaults to t, which would make the negative
  ;; assertion below match the lowercase form and pass vacuously.
  (let ((case-fold-search nil)
        (signature (emacs-query--signature 'save-buffer)))
    (should (string-match-p "&optional" signature))
    (should-not (string-match-p "&OPTIONAL" signature))))

;;;; Handlers

(ert-deftest emacs-query-test-describe-function ()
  (let ((report (emacs-query-describe "save-buffer")))
    (should (string-match-p "## Command: save-buffer" report))
    (should (string-match-p "Signature: (save-buffer &optional ARG)" report))
    (should (string-match-p "Defined in: .*files\\.el:[0-9]+" report))
    ;; The usage line belongs in Signature, not repeated in the docstring.
    (should-not (string-match-p "(fn &optional ARG)" report))))

(ert-deftest emacs-query-test-describe-variable ()
  (let ((report (emacs-query-describe "fill-column")))
    (should (string-match-p "## Variable: fill-column" report))
    (should (string-match-p "Buffer-local when set: yes" report))
    (should (string-match-p "Customizable: yes" report))))

(ert-deftest emacs-query-test-describe-face ()
  (should (string-match-p "## Face: mode-line"
                          (emacs-query-describe "mode-line"))))

(ert-deftest emacs-query-test-describe-unknown-signals ()
  (should-error (emacs-query-describe "no-such-symbol-xyzzy")
                :type 'emacs-query-not-found))

(ert-deftest emacs-query-test-apropos-caps-and-labels ()
  (let* ((emacs-query-limit 3)
         (report (emacs-query-apropos "\\`save-buffer")))
    (should (string-match-p "## Functions" report))
    (should (string-match-p "save-buffer --" report)))
  (should-error (emacs-query-apropos "\\`no-such-prefix-xyzzy")
                :type 'emacs-query-not-found))

(ert-deftest emacs-query-test-macroexpand ()
  (should (string-match-p "(if a (progn b))"
                          (emacs-query-macroexpand "(when a b)"))))

(ert-deftest emacs-query-test-eval ()
  (should (string-match-p "^## Value\n\n3$" (emacs-query-eval "(+ 1 2)")))
  ;; An embedded newline must survive the round trip intact.
  (should (string-match-p "\"a\\\\nb\"" (emacs-query-eval "(concat \"a\\nb\")"))))

(ert-deftest emacs-query-test-library ()
  (let ((report (emacs-query-library "subr-x")))
    (should (string-match-p "## Library: subr-x" report))
    (should (string-match-p "subr-x\\.el" report)))
  (should-error (emacs-query-library "no-such-library-xyzzy")
                :type 'emacs-query-not-found))

(ert-deftest emacs-query-test-keys-both-directions ()
  (should (string-match-p "Runs: save-buffer" (emacs-query-keys "C-x C-s")))
  (let ((report (emacs-query-keys "save-buffer")))
    (should (string-match-p "## Command: save-buffer" report))
    (should (string-match-p "C-x C-s" report))
    ;; Menu-bar pseudo-bindings are noise for an agent.
    (should-not (string-match-p "<menu-bar>" report))))

(ert-deftest emacs-query-test-unknown-subcommand-signals ()
  (should-error (emacs-query--run "nosuch" "x" "no")
                :type 'emacs-query-usage)
  (should-error (emacs-query--run "describe" "" "no")
                :type 'emacs-query-usage))

;;; emacs-query-test.el ends here
