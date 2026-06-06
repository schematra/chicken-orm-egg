# ORM-DB-SQLite

SQLite3 backend for the [`orm`](orm.md) abstract database interface.

## Description

`orm-db-sqlite` implements the `orm-db` backend protocol on top of CHICKEN's `sqlite3` bindings. It provides a single constructor, `sqlite3-backend`, which returns a backend alist suitable for `db/backend`. SQL is generated through the `ssql` egg using a registered `sqlite3` dialect.

## Requirements

- CHICKEN Scheme 5.0 or later
- Dependencies: `orm`, `sqlite3`, `ssql`, `logger`
- SQLite3 development libraries (required by the `sqlite3` egg's C binding)

## Installation

```bash
chicken-install orm-db-sqlite
```

## Basic Usage

```scheme
(import orm-db orm-db-sqlite orm)

;; Select the backend and open a file-based database
(db/backend (sqlite3-backend))
(db/path "myapp.db")
(db/connect)

(define-model users)
(users/all)

(db/close)
```

The `db/path` value is a SQLite database file path. Use `":memory:"` for a transient in-memory database.

```scheme
(db/path ":memory:")
```

## API

#### `(sqlite3-backend)`

Returns a backend alist implementing the `orm-db` protocol — the keys `connect`, `close`, `query`, and `execute` — backed by the `sqlite3` egg. Pass the result to `db/backend`.

```scheme
(db/backend (sqlite3-backend))
```

The backend procedures are used by `orm-db`; you do not normally call them directly:

- **connect**: opens the SQLite database at `db/path`
- **close**: finalizes and closes the connection
- **query**: runs a SELECT, returning a vector of alists
- **execute**: runs a statement, returning the requested output value (e.g. `rows_affected`, `last_insert_rowid`)

## SQL Dialect

The backend registers an `ssql` `sqlite3` dialect (derived from the ANSI translator) so `ssql` S-expression forms passed to `db/query` / `db/execute` render as SQLite-compatible SQL. Raw SQL strings are passed through unchanged.

## License

Copyright © 2026 Rolando Abarca. Released under the BSD-3-Clause license.

## Repository

Part of the [chicken-orm-egg](https://github.com/schematra/chicken-orm-egg) project. See [`orm`](orm.md) for the ORM itself.
