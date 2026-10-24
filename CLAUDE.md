# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ORM for CHICKEN Scheme 5 with pluggable database backends. The repo contains three eggs (packages) in a single flat directory:

- **orm** (`orm.egg`) - Bundles three modules so the lightweight, pure-Scheme pieces install as one unit:
  - `orm-db` (`orm-db.scm`) - Abstract database interface using parameters and alist-based backend dispatch
  - `orm` (`orm.scm`) - Core ORM with `define-model` macro, migrations, relationships
  - `orm-test` (`orm-test.scm`) - Test helpers with `make-mock-backend` for mocking the DB layer
- **orm-db-sqlite** (`orm-db-sqlite.scm`, `orm-db-sqlite.egg`) - SQLite3 backend (depends on `orm` + `sqlite3`)
- **orm-db-rqlite** (`orm-db-rqlite.scm`, `orm-db-rqlite.egg`) - rqlite (HTTP-based distributed SQLite) backend (depends on `orm` + the HTTP/JSON stack)

The backends stay separate eggs because each pulls heavy, mutually-exclusive dependencies (`sqlite3` C binding vs. the `http-client`/`medea`/`intarweb`/`uri-common` stack), and CHICKEN `.egg` files have no per-component optional dependencies. Module names are unchanged, so consumer `(import orm-db)` / `(import orm-test)` still work — only the install unit changed.

## Build & Install

```sh
# Build and install all eggs locally (from repo root)
chicken-install -n
```

Tests: `csi -s tests/run-tests.scm`. With `-n` nothing is installed, so to test the local build rather than the installed egg, put the repo first on the repository path: `CHICKEN_REPOSITORY_PATH=$PWD:$(chicken-install -repository) csi -s tests/run-tests.scm`

## Architecture

### Backend System
`orm-db` defines a backend-agnostic interface using CHICKEN parameters (`db/backend`, `db/connection`, `db/path`). Backends are alists mapping symbols (`connect`, `close`, `query`, `execute`, and optionally `batch`) to procedures. The backend functions `sqlite3-backend` and `rqlite-backend` return these alists. `db/batch` runs a list of `(ssql-or-string . params)` reads and returns a list of row vectors: rqlite implements `batch` natively (one POST to `/db/request`), everything else falls back to `query` per statement.

### SQL Generation
Both backends use the `ssql` egg for S-expression SQL. Dialect translators are in included files (not modules):
- `ssql-sqlite3.scm` - Registers `'sqlite3` dialect, derives from `*ansi-translator*`
- `ssql-rqlite.scm` - Registers `'rqlite` dialect, delegates to the sqlite3 translator

These files are `include`d into their respective backend modules.

### The `define-model` Macro
`define-model` is an `er-macro-transformer` that generates the model's functions: `users/q` (the only read entry point, returns a query descriptor), `users/create`, `users/save`, `users/update`, `users/delete`, `users/columns`, `users/pkey`, `users/load-metadata`. It introspects table schema at runtime via `PRAGMA table_info`. All query results use kebab-case keys (auto-converted from snake_case). It also generates `<table>/hooks`, an accessor for the model's lifecycle hook registry (backed by the private `<table>/%hooks`), plus the private `<table>/%scope`.

### Query Descriptors
Reads are values: `users/q` returns an immutable `model-query` record (table, columns thunk, scope, conditions, order, limit, offset, shape `rows`|`first`|`count`, thens). The `q/` builders (`q/where`, `q/order`, `q/limit`, `q/offset`, `q/first`, `q/count`, `q/by-id`, `q/then`) take the descriptor first and return a new one. Runners: `q/run` (one `db/query`), `q/run-list` / `q/run-all` (one `db/batch`).

Invariants worth preserving:
- **Building never touches the DB or the scope.** Rendering happens only in a runner.
- **The scope applies at render time, last.** Caller conditions are folded into one `and` first, then `apply-model-scope-condition` ANDs the scope in, so its procedure sees the caller's `parameterize` at run time and fails closed as before.
- **`q/run-list` renders everything before sending**, so a scope error in one descriptor sends no batch.
- Internal re-fetches in create/save/update go through `users/q` too, so they stay scoped.

### `model/has-many` Macro
Another `er-macro-transformer` that generates relationship functions. Assumes convention: child table has `<singular-parent>-id` foreign key column. Reads return descriptors: `users/posts/q parent-row` and `posts/users/q child-row` (a `q/first`; a missing/NULL FK gives a descriptor matching nothing). `users/add-posts` is a write and runs immediately.

### Lifecycle Hooks
`model/hook` is a third `er-macro-transformer`, pure sugar over `(model-hooks-add! (<table>/hooks) 'event proc)`. Six events map 1:1 onto the generated functions: `before-create`/`after-create`, `before-save`/`after-save`, `before-delete`/`after-delete`. There is no `before-update` because `users/update` delegates to `users/save`.

Invariants worth preserving:
- **Hooks do not cascade.** `create` fires only the create hooks (unlike ActiveRecord).
- **`before-*` hooks are a left fold** (`row -> row`, registration order); **`after-*` hooks are observers** whose return values are discarded.
- **Hooks run before `apply-model-scope-write`.** The scope is the security boundary and must be the last writer, so a hook can never clobber a scope-injected column. `tests/orm-tests.scm` pins this.
- `run-after-hooks` takes the post-write re-fetch directly and returns it, so generated code uses it as its tail expression. It handles the `#f` (out-of-scope write) case by logging a warning and skipping the hooks. The warning must live in `run-after-hooks` rather than in the expansion, because `w` is bound in orm's module, not in the model's.

### Naming Convention
Scheme kebab-case (`created-at`) auto-converts to/from SQL snake_case (`created_at`) via `symbol->db-column` and `db-column->symbol`.

### Data Representations
- Query results: vector of alists (each alist is a row)
- Single row: alist with symbol keys
- SQL NULL: represented as the symbol `'null`
- Metadata columns: TEXT storing s-expression alists, parsed via `row-metadata`

## Key Dependencies

- `ssql` - S-expression to SQL translation
- `foops` - Object system (used by ssql translators)
- `logger` - Logging (each module installs its own logger tag)
- `sqlite3` - SQLite3 bindings (for orm-db-sqlite)
- `http-client`, `medea`, `intarweb`, `uri-common` - HTTP/JSON (for orm-db-rqlite)
