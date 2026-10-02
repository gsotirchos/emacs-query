---
name: emacs-query
description: >-
  Answer any question about Emacs, Emacs Lisp, or the user's Emacs configuration
  by running the `emacs-query` command, which asks Emacs itself. Use it for what
  a function, macro, command, variable or face does; its signature, value,
  obsolescence, or defining file and line; which key runs a command; what a
  `use-package` form expands to; what the Emacs or Elisp manual says; what a
  library provides. Strongly prefer it over grep, rg, find or sed across
  init.el, early-init.el, site-lisp/ or elpa/, and over web searches for Emacs
  documentation: those read source text, while emacs-query reports what Emacs
  actually resolves.
tools: Bash
---

# Ask Emacs, don't grep it

`emacs-query` is already on `PATH`. Each query runs a throwaway batch Emacs; the
user's own running Emacs is never contacted and nothing is written. Run
`emacs-query --help` for the complete reference.

| Command | Answers |
| --- | --- |
| `emacs-query describe SYMBOL` | Kind, signature, value, obsolescence, `file:line`, docstring |
| `emacs-query apropos REGEXP` | Matching functions, variables and faces, each with its first doc line |
| `emacs-query keys KEY\|COMMAND` | The command a key runs, or the keys that run a command |
| `emacs-query info QUERY` | The Elisp/Emacs manual node for a symbol |
| `emacs-query library NAME` | A library's path, headers and commentary |
| `emacs-query macroexpand SEXP` | `macroexpand-all`, pretty-printed |
| `emacs-query eval SEXP` | Anything else |

Add `--mode MODE` to resolve `keys` inside a major mode, and `--limit N` to
widen a capped list. Exit status 3 means nothing matched; try `apropos`.

## Do not

- Do not grep `init.el`, `site-lisp/` or `elpa/` for a definition, a docstring
  or a keybinding. `describe` gives the exact `file:line` and the resolved
  docstring, including for packages that are installed but not loaded.
- Do not fetch the Emacs or Elisp manual from the web. `info` reads the
  manuals installed locally.
- Do not reason about what a `use-package` keyword does. Expand the form.

## Examples

Where something is defined and what it does, instead of
`grep -rn "(defun consult-ripgrep" ~/.emacs.d/elpa/`:

```sh
emacs-query describe consult-ripgrep
```

What a configuration form actually does. Use `-` to read the form from stdin so
no shell quoting is involved:

```sh
emacs-query macroexpand - <<'EOF'
(use-package corfu
  :ensure t
  :bind ("C-c c" . corfu-mode)
  :custom (corfu-auto t))
EOF
```

A key binding as the user has actually configured it:

```sh
emacs-query keys "C-c C-c" --mode org-mode
emacs-query keys org-capture
```

## Load tiers

Most queries do not need the user's `init.el`, so by default it is not loaded
and answers come back in about a second. Questions that *do* need it —
configured variable values, hook contents, keybindings — are handled
automatically: `keys` always loads it, and `describe`/`apropos` retry with it
when the fast tier finds nothing. Pass `--config` to force it, or
`--no-config` to forbid it.

## Several questions in a row

Standing up one reusable Emacs makes each query roughly 20 times faster
(~0.08 s instead of ~1.8 s). Worth it for a run of questions:

```sh
emacs-query daemon start    # optionally --config
emacs-query describe ...    # every query now routes through it
emacs-query daemon stop     # your job; it outlives this shell
```

`emacs-query daemon status` reports whether one is up. It uses its own private
socket, so it can never interfere with the user's editing session.
