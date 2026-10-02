;;; emacs-query.el --- Core-Emacs introspection for coding agents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 George Sotirchos

;; Author: George Sotirchos
;; URL: https://github.com/gsotirchos/emacs-query
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: docs, help, tools
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Answers questions about Emacs, Emacs Lisp and the user's configuration by
;; asking Emacs itself, so an agent need not grep the configuration tree.
;;
;; Driven by `bin/emacs-query', never loaded into an interactive session.  Two
;; entry points share one set of handlers:
;;
;;   `emacs-query-batch-main'  reads the EMACS_QUERY_* environment and prints
;;                             the report to stdout, for `emacs --batch'.
;;   `emacs-query-serve'       reads its payload from a file and writes the
;;                             report to another, for `emacsclient --eval'
;;                             against a reusable daemon.
;;
;; Both exist because neither transport can carry an arbitrary string the other
;; way round: a daemon does not inherit the caller's environment, and
;; `emacsclient --eval' returns a `prin1'-escaped string.  Each handler
;; therefore returns a string and knows nothing about how it travels.
;;
;; Two load tiers.  The fast tier activates the installed packages and requires
;; the user's `site-lisp' libraries, which covers documentation, locations and
;; apropos.  The config tier additionally loads `init.el', which is the only way
;; to reach configured values, hook contents and keybindings.  The config tier
;; deliberately skips `early-init.el' and disables package installation: a query
;; must never write to the user's configuration or reach the network.

;;; Code:

(require 'apropos)
(require 'find-func)
(require 'help-fns)
(require 'info)
(require 'info-look)
(require 'lisp-mnt)
(require 'package)
(require 'pp)
(require 'seq)
(require 'subr-x)

;; Defined by `use-package', which the config tier requires at run time.
(defvar use-package-always-ensure)

;;;; Options

(defvar emacs-query-limit 40
  "Maximum number of matches reported per section.")

(defvar emacs-query-max-lines 400
  "Hard ceiling on the number of lines in a report.")

(defvar emacs-query-print-length 32
  "Value of `print-length' used when pretty-printing values.")

(defvar emacs-query-print-level 4
  "Value of `print-level' used when pretty-printing values.")

(defvar emacs-query-unsafe-functions
  '(package-install
    package-install-file
    package-install-from-buffer
    package-vc-install
    package-vc-install-selected-packages
    package-refresh-contents
    package-recompile
    package-recompile-all
    package-generate-autoloads
    package-download-transaction
    server-start
    server-force-delete)
  "Functions overridden with `ignore' before the user's config is loaded.
Each either writes to the user's configuration, reaches the network, or
would hijack the Emacs server.  See the URL in the Commentary.")

(defvar emacs-query-tier nil
  "Tier this session was bootstrapped in: nil, `fast' or `config'.")

;;;; Plumbing

(defun emacs-query--getenv (name &optional default)
  "Return environment variable NAME, or DEFAULT when unset or empty."
  (let ((value (getenv name)))
    (if (and value (not (string-empty-p value))) value default)))

(defun emacs-query--warn (format-string &rest args)
  "Write FORMAT-STRING with ARGS to stderr.
`princ' alone writes to stdout, which is reserved for the report."
  (princ (apply #'format (concat "emacs-query: " format-string "\n") args)
         #'external-debugging-output))

(defun emacs-query--site-lisp ()
  "Return the user's `site-lisp' directory, or nil when absent."
  (let ((dir (expand-file-name "site-lisp" user-emacs-directory)))
    (and (file-directory-p dir) dir)))

(defun emacs-query--bootstrap-fast ()
  "Activate installed packages and require the user's own libraries.
This is enough for documentation, locations and apropos, and it never
loads the user's `init.el'."
  (setq package-user-dir (expand-file-name "elpa" user-emacs-directory))
  (condition-case err
      (package-activate-all)
    (error (emacs-query--warn "package activation failed: %S" err)))
  (when-let* ((dir (emacs-query--site-lisp)))
    (add-to-list 'load-path dir)
    ;; Without this the user's own symbols are not interned, so `apropos' and
    ;; `describe' silently report nothing for them.
    (dolist (file (directory-files dir nil "\\.el\\'"))
      (let ((feature (intern (file-name-base file))))
        (condition-case err
            (require feature nil t)
          (error (emacs-query--warn "cannot require %s: %S" feature err))))))
  (setq emacs-query-tier 'fast))

(defun emacs-query--neutralize ()
  "Override every function in `emacs-query-unsafe-functions' with `ignore'."
  (dolist (function emacs-query-unsafe-functions)
    (when (fboundp function)
      (advice-add function :override #'ignore))))

(defun emacs-query--bootstrap-config ()
  "Load the user's `init.el' on top of the fast tier.
`early-init.el' is skipped on purpose: it regenerates autoloads,
refreshes archives and can recompile every installed package.  The
`use-package' bootstrap it performs is redone here without those
side effects."
  (unless (eq emacs-query-tier 'config)
    (emacs-query--neutralize)
    (condition-case err
        (require 'use-package)
      (error (emacs-query--warn "cannot require use-package: %S" err)))
    ;; `early-init.el' sets this to t, which would make every `use-package'
    ;; form lacking `:ensure nil' try to install its package.
    (setq use-package-always-ensure nil)
    (let ((init (expand-file-name "init.el" user-emacs-directory)))
      (if (not (file-readable-p init))
          (emacs-query--warn "no init.el in %s" user-emacs-directory)
        (condition-case err
            (load init nil t)
          (error
           (emacs-query--warn "init.el failed to load fully: %S" err)
           (emacs-query--warn "the report below may be incomplete")))))
    (setq emacs-query-tier 'config)))

(defun emacs-query--bootstrap (config)
  "Bootstrap the fast tier, and the config tier too when CONFIG is non-nil."
  (unless emacs-query-tier
    (emacs-query--bootstrap-fast))
  (when config
    (emacs-query--bootstrap-config)))

;;;; Formatting

(defun emacs-query--pp (value)
  "Pretty-print VALUE, bounded structurally rather than by truncation."
  (let ((print-length emacs-query-print-length)
        (print-level emacs-query-print-level)
        (print-circle t))
    (string-trim-right (pp-to-string value))))

(defun emacs-query--first-line (text)
  "Return the first line of TEXT, or an empty string when TEXT is nil."
  (if text (car (split-string text "\n")) ""))

(defun emacs-query--section (title body)
  "Format BODY under a heading TITLE, or nil when BODY is empty."
  (unless (or (null body) (string-empty-p (string-trim body)))
    (format "## %s\n\n%s\n" title (string-trim-right body))))

(defun emacs-query--join (sections)
  "Join non-nil SECTIONS into one report."
  (string-join (delq nil sections) "\n"))

(defun emacs-query--capped (items)
  "Return ITEMS capped to `emacs-query-limit', plus a footer line.
The footer names how many were omitted, or is nil when none were."
  (let ((total (length items)))
    (cons (seq-take items emacs-query-limit)
          (when (> total emacs-query-limit)
            (format "\n(%d more of %d; raise with --limit)"
                    (- total emacs-query-limit) total)))))

(defun emacs-query--truncate (text)
  "Cap TEXT at `emacs-query-max-lines' lines."
  (let ((lines (split-string text "\n")))
    (if (<= (length lines) emacs-query-max-lines)
        text
      (concat (string-join (seq-take lines emacs-query-max-lines) "\n")
              (format "\n\n... truncated; %d more lines (raise with --limit)"
                      (- (length lines) emacs-query-max-lines))))))

;;;; Symbol introspection

(defun emacs-query--force-autoload (symbol)
  "Load SYMBOL's real definition when its slot still holds an autoload.
Until then `help-function-arglist' cannot report a signature."
  (when (and (fboundp symbol) (autoloadp (symbol-function symbol)))
    (condition-case err
        (autoload-do-load (symbol-function symbol) symbol)
      (error (emacs-query--warn "cannot autoload %s: %S" symbol err)))))

(defun emacs-query--function-kind (symbol)
  "Return a human label for the kind of function SYMBOL is.
Note that `subrp' is useless here: a native-compiled Lisp function
satisfies it, so only `subr-primitive-p' identifies a real built-in."
  (let ((definition (symbol-function symbol)))
    (cond ((special-form-p definition) "Special form")
          ((macrop symbol) "Macro")
          ((subr-primitive-p definition) "Built-in function")
          ((and (commandp symbol) (function-alias-p symbol)) "Command alias")
          ((function-alias-p symbol) "Function alias")
          ((commandp symbol) "Command")
          (t "Function"))))

(defun emacs-query--locate (symbol type)
  "Return \"FILE:LINE\" where SYMBOL of TYPE is defined, or nil.
TYPE is `defvar', `defface', or the function object itself.  Three APIs
are needed: `find-lisp-object-file-name' alone reports the symbol
`C-source' for a primitive and a bare C file name for a built-in
variable, neither of which is a path."
  (let ((file (ignore-errors (find-lisp-object-file-name symbol type))))
    (cond
     ((null file) nil)
     ((eq file 'C-source)
      (format "%s (C source, not installed)"
              (or (ignore-errors (help-C-file-name type 'subr)) "unknown")))
     ((not (string-suffix-p ".el" file))
      (format "%s (C source)" file))
     (t
      (let ((found (ignore-errors
                     (find-function-search-for-symbol
                      symbol (and (memq type '(defvar defface)) type) file))))
        (if (and (consp found) (car found) (cdr found))
            (with-current-buffer (car found)
              (format "%s:%d" file (line-number-at-pos (cdr found) t)))
          file))))))

(defun emacs-query--obsolete-note (symbol)
  "Return an obsolescence warning for SYMBOL, or nil.
Worth leading with: it is the one thing reading the source cannot say."
  (let ((function-info (get symbol 'byte-obsolete-info))
        (variable-info (get symbol 'byte-obsolete-variable)))
    (when-let* ((info (or function-info variable-info)))
      (let ((replacement (car info))
            (when (nth 2 info)))
        (concat "OBSOLETE"
                (if when (format " since %s" when) "")
                (cond ((stringp replacement) (format "; %s" replacement))
                      ((symbolp replacement) (format "; use `%s' instead"
                                                     replacement))
                      (t "")))))))

;;;; Handlers
;;
;; Each takes the payload string and returns the report as a string.

(defun emacs-query--signature (symbol)
  "Return SYMBOL's calling convention as a string.
Prefers the docstring's own usage line, which already spells arguments
the way Emacs documents them, and falls back to the raw arglist."
  (let ((arglist (help-function-arglist symbol t)))
    (cond
     ((stringp arglist) arglist)
     ((listp arglist)
      (format "(%s)"
              (string-join
               (cons (symbol-name symbol)
                     (mapcar (lambda (argument)
                               (let ((name (format "%s" argument)))
                                 ;; `&optional' and `&rest' stay lowercase.
                                 (if (string-prefix-p "&" name)
                                     name
                                   (upcase name))))
                             arglist))
               " ")))
     (t (format "%s" arglist)))))

(defun emacs-query--describe-function (symbol)
  "Return the function report for SYMBOL, or nil when it is not one."
  (when (fboundp symbol)
    (emacs-query--force-autoload symbol)
    (let* ((raw (documentation symbol t))
           (split (help-split-fundoc raw symbol))
           (alias (function-alias-p symbol))
           (location (emacs-query--locate symbol (symbol-function symbol))))
      (emacs-query--section
       (format "%s: %s" (emacs-query--function-kind symbol) symbol)
       (emacs-query--join
        (list
         (when-let* ((note (emacs-query--obsolete-note symbol)))
           (concat note "\n"))
         (format "Signature: %s"
                 (or (car split) (emacs-query--signature symbol)))
         (when alias (format "Alias for: %s" (car (last alias))))
         (format "Interactive: %s" (if (commandp symbol) "yes" "no"))
         (when location (format "Defined in: %s" location))
         (concat "\n" (or (cdr split) raw
                          "No documentation available."))))))))

(defun emacs-query--describe-variable (symbol)
  "Return the variable report for SYMBOL, or nil when it is not one."
  (when (boundp symbol)
    (let* ((value (symbol-value symbol))
           (default (default-value symbol))
           (location (emacs-query--locate symbol 'defvar))
           (standard (get symbol 'standard-value)))
      (emacs-query--section
       (format "Variable: %s" symbol)
       (emacs-query--join
        (list
         (when-let* ((note (emacs-query--obsolete-note symbol)))
           (concat note "\n"))
         (format "Value: %s" (emacs-query--pp value))
         (unless (equal value default)
           (format "Default value: %s" (emacs-query--pp default)))
         (unless (eq emacs-query-tier 'config)
           "Note: built-in default; re-run with --config for the configured value")
         (format "Buffer-local when set: %s"
                 (if (local-variable-if-set-p symbol) "yes" "no"))
         (when (custom-variable-p symbol)
           (format "Customizable: yes%s"
                   (if standard
                       (format "\nStandard value: %s"
                               (emacs-query--pp
                                (ignore-errors (eval (car standard) t))))
                     "")))
         (when location (format "Defined in: %s" location))
         (concat "\n" (or (documentation-property
                           symbol 'variable-documentation t)
                          "No documentation available."))))))))

(defun emacs-query--describe-face (symbol)
  "Return the face report for SYMBOL, or nil when it is not one."
  (when (facep symbol)
    (emacs-query--section
     (format "Face: %s" symbol)
     (emacs-query--join
      (list
       (when-let* ((location (emacs-query--locate symbol 'defface)))
         (format "Defined in: %s" location))
       (format "Attributes: %s"
               (emacs-query--pp (ignore-errors
                                  (face-all-attributes symbol))))
       (concat "\n" (or (documentation-property
                         symbol 'face-documentation t)
                        "No documentation available.")))))))

(defun emacs-query--describe-feature (symbol)
  "Return the feature report for SYMBOL, or nil when no library matches."
  (when-let* ((library (locate-library (symbol-name symbol))))
    (emacs-query--section
     (format "Feature: %s" symbol)
     (format "Loaded: %s\nLibrary: %s"
             (if (featurep symbol) "yes" "no") library))))

(defun emacs-query-describe (name)
  "Return everything Emacs knows about the symbol named NAME."
  (let* ((symbol (intern-soft name))
         (report (and symbol
                      (emacs-query--join
                       (list (emacs-query--describe-function symbol)
                             (emacs-query--describe-variable symbol)
                             (emacs-query--describe-face symbol)
                             (emacs-query--describe-feature symbol))))))
    (if (and report (not (string-empty-p (string-trim report))))
        report
      (signal 'emacs-query-not-found (list name)))))

(defun emacs-query--apropos-section (title regexp predicate describe)
  "Return a capped apropos section TITLE for REGEXP.
PREDICATE selects the symbols and DESCRIBE returns each one's docstring."
  (let* ((symbols (sort (apropos-internal regexp predicate) #'string<))
         (capped (emacs-query--capped symbols)))
    (when (car capped)
      (emacs-query--section
       title
       (concat
        (mapconcat
         (lambda (symbol)
           (let ((summary (emacs-query--first-line
                           (ignore-errors (funcall describe symbol)))))
             (if (string-empty-p summary)
                 (format "%s" symbol)
               (format "%s -- %s" symbol summary))))
         (car capped)
         "\n")
        (cdr capped))))))

(defun emacs-query-apropos (regexp)
  "Return the functions, variables and faces matching REGEXP."
  (let ((report (emacs-query--join
                 (list
                  (emacs-query--apropos-section
                   "Functions" regexp #'fboundp
                   (lambda (s) (documentation s t)))
                  (emacs-query--apropos-section
                   "Variables" regexp #'boundp
                   (lambda (s) (documentation-property
                                s 'variable-documentation t)))
                  (emacs-query--apropos-section
                   "Faces" regexp #'facep
                   (lambda (s) (documentation-property
                                s 'face-documentation t)))))))
    (if (string-empty-p (string-trim report))
        (signal 'emacs-query-not-found (list regexp))
      report)))

(defmacro emacs-query--with-mode (mode &rest body)
  "Evaluate BODY in a temporary buffer whose major mode is MODE.
Keymaps are what make this necessary: a mode's bindings do not exist
until some buffer actually runs it."
  (declare (indent 1))
  `(with-temp-buffer
     (when ,mode
       (condition-case err
           (funcall ,mode)
         (error (emacs-query--warn "cannot enter %s: %S" ,mode err))))
     ,@body))

(defun emacs-query-keys (input)
  "Return the binding for key sequence INPUT, or the keys running it."
  (let ((mode (when-let* ((name (emacs-query--getenv "EMACS_QUERY_MODE")))
                (intern name))))
    (if (key-valid-p input)
        (let ((command (emacs-query--with-mode mode
                         (key-binding (key-parse input) t))))
          (if (not command)
              (signal 'emacs-query-not-found (list input))
            (emacs-query--section
             (format "Key: %s" input)
             (emacs-query--join
              (list
               (format "Runs: %s%s" command
                       (if mode (format "   (in %s)" mode) ""))
               (when (symbolp command)
                 (when-let* ((location (emacs-query--locate
                                        command (symbol-function command))))
                   (format "Defined in: %s" location)))
               (when (symbolp command)
                 (concat "\n" (or (documentation command t) ""))))))))
      (let* ((command (intern-soft input))
             (keys (and command (fboundp command)
                        (emacs-query--with-mode mode
                          (where-is-internal command nil)))))
        (unless (and command (fboundp command))
          (signal 'emacs-query-not-found (list input)))
        (emacs-query--section
         (format "Command: %s" command)
         (let ((descriptions (seq-remove
                              (lambda (k) (string-prefix-p "<menu-bar>" k))
                              (mapcar #'key-description keys))))
           (if descriptions
               (format "Bound to: %s%s"
                       (string-join descriptions ", ")
                       (if mode (format "   (in %s)" mode) ""))
             (format "Not bound to any key%s"
                     (if mode (format " in %s" mode) "")))))))))

(defun emacs-query-info (query)
  "Return the manual entry for QUERY, and matching index entries."
  (let* ((manual (emacs-query--getenv "EMACS_QUERY_MANUAL"))
         (want-apropos (emacs-query--getenv "EMACS_QUERY_APROPOS"))
         (node
          (condition-case nil
              (save-window-excursion
                (with-temp-buffer
                  (emacs-lisp-mode)
                  (info-lookup-symbol query 'emacs-lisp-mode))
                (with-current-buffer "*info*"
                  (emacs-query--section
                   (format "(%s)%s"
                           (file-name-base (or Info-current-file ""))
                           (or Info-current-node "?"))
                   (buffer-substring-no-properties
                    (point)
                    (save-excursion
                      (forward-line emacs-query-limit)
                      (point))))))
            (error nil)))
         (matches
          (when want-apropos
            (let* ((all (condition-case nil
                            (Info-apropos-matches query t)
                          (error nil)))
                   (filtered (if manual
                                 (seq-filter
                                  (lambda (m) (equal (car m) manual)) all)
                               all))
                   (capped (emacs-query--capped filtered)))
              (when (car capped)
                (emacs-query--section
                 "Index matches"
                 (concat (mapconcat
                          (lambda (m)
                            (format "(%s)%s -- %s"
                                    (car m) (nth 1 m) (nth 2 m)))
                          (car capped) "\n")
                         (cdr capped))))))))
    (if (or node matches)
        (emacs-query--join (list node matches))
      (signal 'emacs-query-not-found (list query)))))

(defun emacs-query-library (name)
  "Return the location and headers of the library named NAME."
  (let ((file (locate-library name)))
    (unless file
      (signal 'emacs-query-not-found (list name)))
    ;; A byte-compiled library carries no headers; read them from the source.
    (let* ((source (if (string-suffix-p ".elc" file)
                       (string-remove-suffix "c" file)
                     file))
           (readable (and (file-readable-p source) source))
           (descriptor (ignore-errors
                         (package-get-descriptor (intern name)))))
      (emacs-query--join
       (list
        (emacs-query--section
         (format "Library: %s" name)
         (emacs-query--join
          (list
           (format "File: %s" file)
           (when (and readable (not (equal readable file)))
             (format "Source: %s" readable))
           (format "Loaded: %s"
                   (if (featurep (intern name)) "yes" "no"))
           (when readable
             (when-let* ((summary (lm-summary readable)))
               (format "Summary: %s" summary)))
           (when readable
             (when-let* ((version (lm-version readable)))
               (format "Version: %s" version)))
           (when readable
             (when-let* ((requires (ignore-errors
                                     (lm-package-requires readable))))
               (format "Requires: %s" (emacs-query--pp requires)))))))
        (when descriptor
          (emacs-query--section
           "Package"
           (format "Version: %s\nSummary: %s\nDirectory: %s"
                   (package-version-join (package-desc-version descriptor))
                   (package-desc-summary descriptor)
                   (package-desc-dir descriptor))))
        (when readable
          (when-let* ((commentary (ignore-errors (lm-commentary readable))))
            (emacs-query--section "Commentary" commentary))))))))

(defun emacs-query-macroexpand (sexp-string)
  "Return SEXP-STRING fully macro-expanded and pretty-printed."
  (let ((form (car (read-from-string sexp-string))))
    ;; `use-package' and friends are autoloaded; expansion needs the real macro.
    (when (consp form)
      (emacs-query--force-autoload (car form)))
    (emacs-query--section
     "Expansion"
     (emacs-query--pp (macroexpand-all form)))))

(defun emacs-query-eval (sexp-string)
  "Evaluate SEXP-STRING lexically and return its pretty-printed value."
  (emacs-query--section
   "Value"
   (emacs-query--pp (eval (car (read-from-string sexp-string)) t))))

;;;; Dispatch

(define-error 'emacs-query-not-found "Nothing found")
(define-error 'emacs-query-usage "Usage error")

(defconst emacs-query-commands
  ;; NAME HANDLER CONFIG-BY-DEFAULT
  '(("describe"    emacs-query-describe    nil)
    ("apropos"     emacs-query-apropos     nil)
    ;; `keys' is the one command whose fast-tier answer would be wrong rather
    ;; than merely empty: without init.el it reports stock Emacs bindings.
    ("keys"        emacs-query-keys        t)
    ("info"        emacs-query-info        nil)
    ("library"     emacs-query-library     nil)
    ("macroexpand" emacs-query-macroexpand nil)
    ("eval"        emacs-query-eval        nil))
  "Table of subcommand name, handler function and default load tier.")

(defun emacs-query--run (command input config)
  "Bootstrap for CONFIG and return COMMAND's report for INPUT.
CONFIG is `yes', `no', or nil to accept the subcommand's default."
  (let ((entry (assoc command emacs-query-commands)))
    (unless entry
      (signal 'emacs-query-usage (list (format "unknown subcommand %S" command))))
    (when (or (null input) (string-empty-p input))
      (signal 'emacs-query-usage (list (format "%s needs an argument" command))))
    (emacs-query--bootstrap (pcase config
                              ("yes" t)
                              ("no" nil)
                              (_ (nth 2 entry))))
    (let ((report (funcall (nth 1 entry) input)))
      ;; Escalate rather than make the agent know about tiers.
      (if (and (not (eq emacs-query-tier 'config))
               (not (equal config "no"))
               (string-empty-p (string-trim (or report ""))))
          (progn (emacs-query--bootstrap-config)
                 (funcall (nth 1 entry) input))
        report))))

(defun emacs-query--run-guarded (command input config)
  "Return COMMAND's report for INPUT under CONFIG, plus an exit code.
The result is a cons of the text to print and the code to exit with.
Escalates to the config tier once when the fast tier finds nothing."
  (condition-case err
      (cons (emacs-query--truncate (emacs-query--run command input config)) 0)
    (emacs-query-not-found
     (if (and (not (eq emacs-query-tier 'config)) (not (equal config "no")))
         ;; A "not found" in the fast tier may just mean init.el defines it.
         (condition-case err2
             (progn
               (emacs-query--bootstrap-config)
               (cons (emacs-query--truncate
                      (emacs-query--run command input "yes"))
                     0))
           (emacs-query-not-found
            (cons (format "Nothing found for %S.\nTry: emacs-query apropos <regexp>"
                          (car (cdr err2)))
                  3)))
       (cons (format "Nothing found for %S.\nTry: emacs-query apropos <regexp>"
                     (car (cdr err)))
             3)))
    (emacs-query-usage
     (cons (format "emacs-query: %s" (car (cdr err))) 2))
    (error
     (cons (format "emacs-query: %s" (error-message-string err)) 1))))

(defun emacs-query-batch-main ()
  "Entry point for `emacs --batch --funcall emacs-query-batch-main'.
Reads the request from the EMACS_QUERY_* environment and prints the
report to stdout."
  (let* ((inhibit-message t)
         (message-log-max nil)
         ;; Never queue native compilation: that writes into the user's
         ;; eln-cache, and a query must not touch their configuration.
         (native-comp-jit-compilation nil)
         (emacs-query-limit (string-to-number
                             (emacs-query--getenv "EMACS_QUERY_LIMIT" "40")))
         (result (emacs-query--run-guarded
                  (emacs-query--getenv "EMACS_QUERY_COMMAND")
                  (emacs-query--getenv "EMACS_QUERY_INPUT")
                  (emacs-query--getenv "EMACS_QUERY_CONFIG"))))
    (if (zerop (cdr result))
        (princ (concat (car result) "\n"))
      (emacs-query--warn "%s" (car result)))
    (kill-emacs (cdr result))))

(defun emacs-query-serve (command input-file output-file &rest options)
  "Run COMMAND on the payload in INPUT-FILE, writing the report to OUTPUT-FILE.
Entry point for `emacsclient --eval' against a reusable daemon; returns
the exit code.  OPTIONS is a plist of :mode, :manual, :apropos, :limit
and :config.  Files carry the payload and the report because
`emacsclient' neither forwards the environment nor returns an unescaped
string."
  (let* ((inhibit-message t)
         (native-comp-jit-compilation nil)
         (emacs-query-limit (or (plist-get options :limit) 40))
         (process-environment
          (append
           (list (format "EMACS_QUERY_MODE=%s" (or (plist-get options :mode) ""))
                 (format "EMACS_QUERY_MANUAL=%s"
                         (or (plist-get options :manual) ""))
                 (format "EMACS_QUERY_APROPOS=%s"
                         (or (plist-get options :apropos) "")))
           process-environment))
         (input (with-temp-buffer
                  (insert-file-contents input-file)
                  (buffer-string)))
         (result (emacs-query--run-guarded
                  command input (plist-get options :config))))
    (with-temp-file output-file
      (insert (car result) "\n"))
    (cdr result)))

(provide 'emacs-query)

;;; emacs-query.el ends here
