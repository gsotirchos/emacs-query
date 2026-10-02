# emacs-query

Answer questions about Emacs, Emacs Lisp and your own configuration by asking
Emacs itself, instead of grepping the configuration tree.

A coding agent that wants to know what `project-files` does, or where
`my/reindent-or-fill-paragraph` is defined, will usually `grep` through
`init.el`, `site-lisp/` and `elpa/`. Emacs already knows all of it precisely,
including for packages that are installed but not loaded. This plugin gives the
agent one command to ask.

```console
$ emacs-query describe project-files
## Function: project-files

Signature: (project-files PROJECT &optional DIRS)
Interactive: no
Defined in: /Applications/Emacs.app/Contents/Resources/lisp/progmodes/project.el:384

Return a list of files in directories DIRS in PROJECT.
...
```

It uses **core Emacs facilities only** — `help-fns`, `find-func`, `apropos`,
`info-look`, `lisp-mnt`, `pp`. No third-party package sits in the introspection
path.

## Subcommands

| Command | Answers | Replaces |
| --- | --- | --- |
| `describe SYMBOL` | Kind, signature, value, obsolescence, `file:line`, docstring | `grep -n "(defun foo"` |
| `apropos REGEXP` | Matching functions, variables and faces with their first doc line | guessing at a symbol name |
| `keys KEY\|COMMAND` | The command a key runs, or the keys that run a command | reading a keybindings file end to end |
| `info QUERY` | The Elisp/Emacs manual node for a symbol | a web search |
| `library NAME` | A library's path, headers and commentary | `find -name "x.el"` |
| `macroexpand SEXP` | `macroexpand-all`, pretty-printed | guessing what a `use-package` form does |
| `eval SEXP` | Anything else | — |
| `daemon start\|stop\|status` | A reusable Emacs, so queries skip the bootstrap | — |

Run `emacs-query --help` for every option.

Two things worth calling out, because reading the source cannot tell you either:

- `describe` leads with **obsolescence**. `emacs-query describe if-let` reports
  that it is obsolete as of Emacs 31.1 and that `if-let*` replaces it.
- `macroexpand` reads your installed macros, so a `use-package` form expands
  into the `autoload`, `define-key` and `custom-set` calls it really performs.

Any argument may be `-` to read it from standard input, which avoids shell
quoting altogether:

```sh
emacs-query macroexpand - <<'EOF'
(use-package corfu
  :ensure t
  :bind ("C-c c" . corfu-mode))
EOF
```

## Load tiers

Most questions do not need your `init.el`, so by default it is not loaded.

- **Fast tier** (default, ~1.8 s): activates your installed packages and
  requires your `site-lisp` libraries. Enough for documentation, definition
  locations, apropos, manuals and macro expansion.
- **Config tier** (`--config`): also loads `init.el`, which is the only way to
  see configured variable *values*, hook contents and keybindings.

You rarely need to choose. `keys` always loads the config, because without it
the answer would be stock Emacs rather than yours. `describe` and `apropos`
retry with the config automatically when the fast tier finds nothing, so a
symbol defined inside a `use-package` body is still found. `--no-config`
forbids the escalation.

### The config tier never writes and never uses the network

Loading a real `init.el` in batch is only safe if it cannot install anything.
Before loading it, `emacs-query`:

- **skips `early-init.el` entirely**, since that is typically where autoload
  regeneration, archive refreshes and post-upgrade recompilation live, and
  redoes only the `use-package` bootstrap itself;
- forces `use-package-always-ensure` to `nil`, so a form without `:ensure nil`
  cannot install its package;
- overrides `package-install`, `package-refresh-contents`,
  `package-recompile-all`, `package-generate-autoloads` and friends with
  `ignore`;
- binds `native-comp-jit-compilation` to `nil`, so nothing is written to your
  `eln-cache`;
- loads `init.el` inside `condition-case`, reporting a failure on stderr and
  marking the answer as possibly incomplete rather than dying.

A query never contacts your running Emacs, and never writes to your
configuration.

## Installation

Requires Emacs 29.1 or newer (for `--init-directory`) and `emacsclient` for the
optional daemon.

```sh
claude plugin marketplace add gsotirchos/emacs-query
claude plugin install emacs-query@gsotirchos-emacs-query
```

Claude Code puts the plugin's `bin/` on the agent's `PATH`, so `emacs-query`
becomes available as a bare command. To avoid a permission prompt per call, add
to `settings.json`:

```json
{
  "permissions": {
    "allow": ["Bash(emacs-query:*)"]
  }
}
```

The bundled skill tells the agent to prefer `emacs-query` over `grep`, `find`
and `sed` for Emacs questions, and over web searches for Emacs documentation.

Outside Claude Code it is an ordinary script: put `bin/` on your `PATH`.

`--init-dir DIR`, or `EMACS_QUERY_INIT_DIR`, points at a configuration other
than `~/.emacs.d`. `EMACS` selects a different Emacs binary.

## A reusable daemon

Each query otherwise pays the bootstrap. For a run of questions, keep one Emacs
alive and every query gets about 20 times faster:

```console
$ emacs-query daemon start
emacs-query: daemon started (pid 64683); stop it with 'emacs-query daemon stop'
$ time emacs-query describe project-files
real    0m0.075s
$ emacs-query daemon stop
```

Queries route through it automatically while it is up, with byte-identical
output, so turning it on is purely a speed change. It runs on its own private
socket and never touches the `server` socket your editor uses. It also outlives
the shell that started it, so stop it when you are done.

## Development

```sh
# Unit tests
emacs -Q --batch -l lisp/emacs-query.el -l test/emacs-query-test.el \
      -f ert-run-tests-batch-and-exit

# End-to-end, including argument parsing, exit codes and the daemon
./test/smoke.sh

# Linting
shellcheck bin/emacs-query test/smoke.sh
bashate bin/emacs-query test/smoke.sh
emacs -Q --batch -f batch-byte-compile lisp/emacs-query.el
```

An installed copy lives in `~/.claude/plugins/cache/`, so editing a clone does
not change it. For iterating, load the clone straight from disk, which
overrides the installed copy for that session:

```sh
claude --plugin-dir /path/to/emacs-query
```

The manifest pins no `version`, so an installed copy tracks the commit SHA:
every push reaches `claude plugin update` and marketplace auto-update.

The ERT suite uses core Emacs symbols only, so it passes without your
configuration and without network access. `emacs-query-test-function-kind` is a
regression test worth keeping: a native-compiled Lisp function satisfies
`subrp`, so classifying functions with it would label most of Emacs
"built-in". Only `subr-primitive-p` identifies a real primitive.

## License

MIT
