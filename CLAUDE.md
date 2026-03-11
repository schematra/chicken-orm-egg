# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ORM for CHICKEN Scheme 5 with pluggable database backends. The repo contains three separate eggs (packages) in a single flat directory:

- **orm-db** (`orm-db.scm`, `orm-db.egg`) - Abstract database interface using parameters and alist-based backend dispatch
- **orm-db-sqlite** (`orm-db-sqlite.scm`, `orm-db-sqlite.egg`) - SQLite3 backend
- **orm-db-rqlite** (`orm-db-rqlite.scm`, `orm-db-rqlite.egg`) - rqlite (HTTP-based distributed SQLite) backend
- **orm** (`orm.scm`, `orm.egg`) - Core ORM with `define-model` macro, migrations, relationships
- **orm-test** (`orm-test.scm`, `orm-test.egg`) - Test helpers with `make-mock-backend` for mocking the DB layer

## Build & Install

```sh
# Build and install all eggs locally (from repo root)
chicken-install -n
```

Tests: `csi -s tests/run-tests.scm`

## Architecture

### Backend System
`orm-db` defines a backend-agnostic interface using CHICKEN parameters (`db/backend`, `db/connection`, `db/path`). Backends are alists mapping symbols (`connect`, `close`, `query`, `execute`) to procedures. The backend functions `sqlite3-backend` and `rqlite-backend` return these alists.

### SQL Generation
Both backends use the `ssql` egg for S-expression SQL. Dialect translators are in included files (not modules):
- `ssql-sqlite3.scm` - Registers `'sqlite3` dialect, derives from `*ansi-translator*`
- `ssql-rqlite.scm` - Registers `'rqlite` dialect, delegates to the sqlite3 translator

These files are `include`d into their respective backend modules.

### The `define-model` Macro
`define-model` is an `er-macro-transformer` that generates ~10 CRUD functions per model (e.g., `users/all`, `users/find`, `users/where`, `users/create`, `users/save`, `users/delete`). It introspects table schema at runtime via `PRAGMA table_info`. All query results use kebab-case keys (auto-converted from snake_case).

### `model/has-many` Macro
Another `er-macro-transformer` that generates relationship functions. Assumes convention: child table has `<singular-parent>-id` foreign key column.

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
