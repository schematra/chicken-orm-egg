# ORM-DB-rqlite

rqlite backend for the [`orm`](orm.md) abstract database interface.

## Description

`orm-db-rqlite` implements the `orm-db` backend protocol against [rqlite](https://rqlite.io), a lightweight, distributed relational database built on SQLite that is accessed over HTTP. It provides a single constructor, `rqlite-backend`, which returns a backend alist suitable for `db/backend`. Because rqlite speaks SQLite SQL, this backend reuses the `sqlite3` `ssql` dialect.

The connection is stateless: each query and statement is sent as an HTTP request to the rqlite cluster, so there is no persistent socket to manage — `db/close` is a no-op.

## Requirements

- CHICKEN Scheme 5.0 or later
- Dependencies: `orm`, `ssql`, `http-client`, `uri-common`, `intarweb`, `medea`, `logger`
- A running rqlite server or cluster

## Installation

```bash
chicken-install orm-db-rqlite
```

## Basic Usage

```scheme
(import orm-db orm-db-rqlite orm)

;; Select the backend; db/path is the rqlite HTTP base URL
(db/backend (rqlite-backend))
(db/path "http://localhost:4001")
(db/connect)

(define-model users)
(users/all)

(db/close)   ; no-op for rqlite
```

The `db/path` value is the base HTTP URL of the rqlite node, optionally including credentials. Requests are issued against the `/db/request` endpoint with the `timings` and `associative` options.

```scheme
;; With basic-auth credentials and TLS
(db/path "https://user:pass@db.example.com:4001")
```

## API

#### `(rqlite-backend)`

Returns a backend alist implementing the `orm-db` protocol — the keys `connect`, `close`, `query`, and `execute` — backed by rqlite's HTTP API. Pass the result to `db/backend`.

```scheme
(db/backend (rqlite-backend))
```

The backend procedures are used by `orm-db`; you do not normally call them directly:

- **connect**: records the rqlite base URL from `db/path` (no socket is opened)
- **close**: no-op
- **query**: POSTs a SELECT to `/db/request`, returning a vector of alists (rqlite's `associative` mode yields rows keyed by column name)
- **execute**: POSTs a statement and returns the requested output value; rqlite errors are raised as a CHICKEN `(error 'rqlite ...)` condition

## SQL Dialect

The backend includes the `sqlite3` `ssql` dialect and registers an `rqlite` dialect that delegates to it, so `ssql` S-expression forms render as SQLite-compatible SQL. Raw SQL strings are passed through unchanged.

## Notes on Distributed Use

- Every `db/query` / `db/execute` is an independent HTTP round-trip; there is no client-side transaction state.
- Because the connection is just a base URL, the same model code works unchanged against a single rqlite node or a multi-node cluster behind a load balancer.
- This backend pairs naturally with the `orm-migrate` CLI (see [`orm`](orm.md)): `orm-migrate -b rqlite -path "https://user:pass@host:4001" -f migrations.scm`.

## License

Copyright © 2026 Rolando Abarca. Released under the BSD-3-Clause license.

## Repository

Part of the [chicken-orm-egg](https://github.com/schematra/chicken-orm-egg) project. See [`orm`](orm.md) for the ORM itself.
