# ORM

A simple ORM (Object-Relational Mapping) for CHICKEN Scheme with support for models, migrations, and relationships.

## Description

The `orm` egg is a lightweight ORM for CHICKEN Scheme built around a `define-model` macro that introspects an existing table at runtime and generates a full set of CRUD functions. It features a backend-agnostic database layer, a small migration system with a companion CLI runner, has-many relationships, and automatic kebab-case ↔ snake_case name conversion.

The egg bundles three modules so the lightweight, pure-Scheme pieces install as one unit:

- `orm` — the core ORM: models, migrations, relationships
- `orm-db` — the abstract, backend-agnostic database interface
- `orm-test` — a mock backend for testing ORM code without a real database

A database backend is installed separately as its own egg, because each pulls heavy, mutually-exclusive dependencies:

- [`orm-db-sqlite`](orm-db-sqlite.md) — SQLite3 backend
- [`orm-db-rqlite`](orm-db-rqlite.md) — rqlite (HTTP-based distributed SQLite) backend

## Requirements

- CHICKEN Scheme 5.0 or later
- Dependencies: `srfi-1`, `srfi-13`, `srfi-133`, `logger`, `sql-null`
- A backend egg (`orm-db-sqlite` or `orm-db-rqlite`) to connect to a real database

## Installation

```bash
chicken-install orm
chicken-install orm-db-sqlite   # if using SQLite
chicken-install orm-db-rqlite   # if using rqlite
```

## Basic Usage

```scheme
(import orm-db orm-db-sqlite orm)

;; Configure and connect to a database
(db/backend (sqlite3-backend))
(db/path "myapp.db")
(db/connect)

;; Define a model bound to an existing table
(define-model users)

;; Query
(q/run (users/q))                 ; => #(((id . 1) (name . "Alice") ...) ...)
(q/run (q/by-id (users/q) 1))     ; => ((id . 1) (name . "Alice") ...)
```

## Naming Conventions

The ORM automatically converts between Scheme's kebab-case and SQL's snake_case:

- Table name `user-sessions` maps to `user_sessions`
- Column `created-at` maps to `created_at`
- Query results are returned with kebab-case keys

## Data Representations

- **Query results**: a vector of alists, one alist per row
- **Single row**: an alist with symbol keys
- **SQL NULL**: represented as the symbol `null`
- **Metadata columns**: a TEXT column storing an s-expression alist, read/written via `row-metadata` / `row-metadata-set!`

## API: Database Layer (orm-db)

The `orm-db` module defines a backend-agnostic interface using CHICKEN parameters. A backend is an alist mapping the symbols `connect`, `close`, `query`, and `execute` (and optionally `batch`) to procedures; the backend eggs provide constructors (`sqlite3-backend`, `rqlite-backend`) that return such an alist.

#### `(db/backend [backend])`

Parameter. Get or set the current backend alist. Must be set before connecting.

#### `(db/path [path])`

Parameter. Get or set the database path or connection string. Must be set before connecting.

#### `(db/connection [conn])`

Parameter. Get or set the current (opaque, backend-specific) connection. Normally managed by `db/connect` / `db/close`.

#### `(db/connect)`

Open a connection using the current backend and path. Errors if either is unset.

```scheme
(db/backend (sqlite3-backend))
(db/path "myapp.db")
(db/connect)
```

#### `(db/close)`

Close the current connection (no-op if none is open).

#### `(db/query ssql-or-string [params])`

Run a SELECT. `ssql-or-string` is either a raw SQL string or an `ssql` S-expression form; `params` is a list bound to `?` placeholders. Returns a vector of alists.

#### `(db/execute ssql-or-string [params] [out-key])`

Run an INSERT/UPDATE/DELETE/DDL statement. `out-key` selects which value the backend returns (default `rows_affected`; e.g. `last_insert_rowid`).

#### `(db/batch statements)`

Run several read statements and return a list of row vectors, one per statement, in order. `statements` is a list of `(ssql-or-string . params)` pairs. If the backend provides a `batch` entry (`(conn statements) -> list of row vectors`), it is used, so a backend like rqlite can send everything in one request. Otherwise `db/batch` falls back to calling the backend's `query` once per statement. An empty list returns `'()` without touching the backend. Batches are for reads only. `q/run-list` and `q/run-all` are built on it.

```scheme
(db/batch '(("SELECT * FROM users WHERE id = ?" 1)
            ("SELECT COUNT(*) AS n FROM posts")))
; => (#(((id . 1) ...)) #(((n . 12))))
```

## API: Models (define-model)

#### `(define-model name [scope: model-scope])`

Macro. Defines a model bound to the existing table `name`. The macro introspects the table schema at runtime (via `PRAGMA table_info`) and generates the functions below. A live connection must exist when the generated functions are first called.

```scheme
(define-model users)
```

An optional model scope supplies a mandatory query condition and a row
preparation callback:

```scheme
(define current-account-id (make-parameter #f))

(define account-scope
  (make-model-scope
   (lambda ()
     (let ((account-id (current-account-id)))
       (unless account-id (error "account scope required"))
       (values '(= account-id ?) (list account-id))))
   (lambda (row)
     (alist-update 'account-id (current-account-id) row))))

(define-model invoices scope: account-scope)
```

The condition callback takes no arguments and returns two values: an `ssql`
condition and its placeholder-value list. The ORM places this condition before
any caller condition whenever a `users/q` descriptor is run (it is applied at run
time, not when the descriptor is built), and includes it in the same SQL `WHERE`
for `save`, `update`, and `delete`. This makes scoped writes
atomic rather than a check followed by an unscoped primary-key mutation.

The optional write callback receives and returns a row alist. It runs before
`create` and `save`; `update` delegates to a scoped lookup by id and `save`. Use it to
stamp or validate fields required by the scope. If omitted, it defaults to the
identity function.

Scope callbacks should signal an error when required context is unavailable.
A configured scope that returns `#f` as its condition is rejected. Raw
`db/query` and `db/execute` calls are not model operations and bypass scopes.

The model's `before-*` lifecycle hooks run *before* the scope's write callback,
so the scope is always the last writer and a hook cannot overwrite a
scope-injected column. See "API: Lifecycle Hooks" below.

For a model named `users`, the generated functions are listed below. Each example shows the SQL that is produced (the SQLite dialect; rqlite renders identically). Assume `users` has columns `id`, `name`, `email`.

#### `(users/q)`

Return a query descriptor for the model: a value describing a `SELECT` over all of the table's columns, with the model's scope attached. Building and refining a descriptor never touches the database; run it with `q/run` (or batch several with `q/run-all`). See "API: Queries (q/)" below for the builders.

```scheme
(q/run (users/q))
;; SQL: SELECT id, name, email FROM users

(q/run (q/limit (q/order (users/q) '(desc created-at)) 10))
;; SQL: SELECT id, name, email FROM users ORDER BY created_at DESC LIMIT 10

(q/run (q/by-id (users/q) 1))   ; => ((id . 1) ...) or #f
;; SQL: SELECT id, name, email FROM users WHERE (id = ?) LIMIT 1

(q/run (q/count (q/where (users/q) '(= status ?) "active")))   ; => 15
;; SQL: SELECT COUNT(*) AS _count FROM users WHERE (status = ?)
```

The column list comes from the introspected schema. On a scoped model, the scope condition is ANDed in front of the caller's conditions when the descriptor is run, inside whatever `parameterize` is active at that point. A scope that cannot produce its condition signals an error (fails closed).

#### `(users/create row-alist)`

Insert a new row and return it (re-fetched by rowid). Pairs whose value is `'()` are dropped, so only supplied columns are inserted.

Fires `before-create`, then the scope's write callback, then the `INSERT`, then `after-create`. It does not fire the save hooks.

```scheme
(users/create '((name . "Charlie") (email . "charlie@example.com")))
; => ((id . 3) (name . "Charlie") ...)
;; SQL: INSERT INTO users (name, email) VALUES (?, ?)
;;      then re-fetched: SELECT ... FROM users WHERE (rowid = ?) LIMIT 1
```

#### `(users/save row-alist)`

Update an existing row, matched by primary key, and return the fresh row. Only non-primary-key, non-timestamp columns appear in the `SET` list; `updated_at` is always set to `CURRENT_TIMESTAMP`, and `created-at` / `updated-at` in the input are ignored.

Fires `before-save`, then the scope's write callback, then the `UPDATE`, then `after-save`. If the scoped `UPDATE` matches nothing, `save` returns `#f`: `before-save` has already run, but `after-save` is skipped and a warning is logged.

```scheme
(let* ((user (q/run (q/by-id (users/q) 1)))
       (updated (alist-update 'name "Alicia" user)))
  (users/save updated))
;; SQL: UPDATE users SET name = ?, updated_at = CURRENT_TIMESTAMP WHERE (id = ?)
;;      then re-fetched: SELECT ... FROM users WHERE (id = ?) LIMIT 1
```

#### `(users/update id updates)`

Convenience wrapper: find the row by `id`, apply the `updates` alist, and save. Returns the updated row, or `#f` if the id is not found. Because it delegates to `users/save`, it fires the save hooks exactly once. There is no separate `before-update` event.

```scheme
(users/update 1 '((name . "Alicia") (status . "inactive")))
(users/update 999 '((name . "Nobody")))   ; => #f
```

#### `(users/delete row-alist)`

Delete the row identified by the primary key in `row-alist`. Returns `#t`.

Fires `before-delete`, then the `DELETE`, then `after-delete`. Both receive the row the before-hooks returned, and the primary key for the `DELETE` is taken from that same value. The return value is `#t` regardless of how many rows matched, so `after-delete` fires on a no-op delete as well. The scope's write callback is not applied here.

```scheme
(let ((user (q/run (q/by-id (users/q) 1))))
  (users/delete user))
;; SQL: DELETE FROM users WHERE (id = ?)
```

#### `(users/columns)`

Return the table's column metadata.

#### `(users/pkey)`

Return the primary key column name(s) as a list.

#### `(users/hooks)`

Return the model's `model-hooks` registry. This is what makes hooks registrable
from a different module than the one holding the `define-model`, and it is what
the `model/hook` macro expands into.

```scheme
(model-hooks-add! (users/hooks) 'before-create (lambda (row) row))
```

## API: Queries (q/)

Model reads are values. `users/q` returns a query descriptor; the `q/` builders take a descriptor as their first argument and return a new one (descriptors are immutable, so a base query can be shared and refined freely). Nothing is rendered, scoped or sent until a runner (`q/run`, `q/run-list`, `q/run-all`) executes it.

Because the descriptor always comes first, the builders thread naturally with a `->` macro. The `orm` egg does not provide or depend on one: use `->` from an egg such as `clojurist`, or nest the calls.

```scheme
;; with a -> macro
(q/run (-> (users/q)
           (q/where '(= status ?) "active")
           (q/order '(desc created-at))
           (q/limit 10)))

;; the same, nested
(q/run (q/limit (q/order (q/where (users/q) '(= status ?) "active")
                         '(desc created-at))
                10))
```

#### `(make-model-query table columns-thunk scope)`

Create a bare descriptor for `table` (a symbol), where `columns-thunk` returns the column specs (e.g. `users/columns`) and `scope` is a `model-scope` or `#f`. `define-model` generates `users/q` from this; you rarely call it directly.

#### `(model-query? x)`

Return `#t` if `x` is a query descriptor.

#### `(q/where q condition value ...)`

Add an `ssql` condition with `?` placeholders, bound positionally to the `value`s. Several `q/where` calls AND together, and their values are bound in call order. Model field names in the condition are converted to snake_case.

```scheme
(q/where (users/q) '(= status ?) "active")
;; WHERE (status = ?)

(q/where (q/where (users/q) '(= status ?) "active") '(> age ?) 18)
;; WHERE ((status = ?) AND (age > ?))   params: ("active" 18)

(q/where (users/q) '(between age ? ?) 18 65)
(q/where (users/q) '(like name ?) "%alice%")
(q/where (users/q) '(is deleted-at ?) 'null)
;; WHERE (deleted_at IS ?)
```

Comparison operators: `=`, `<>`, `<`, `>`, `<=`, `>=`, `like`, `is`, and anything else `ssql` supports.

#### `(q/order q order)`

Set the ordering. `order` is a field, `(asc field)` or `(desc field)`; kebab-case model fields are converted to snake_case.

```scheme
(q/order (users/q) 'name)               ; ORDER BY name
(q/order (users/q) '(desc created-at))  ; ORDER BY created_at DESC
```

#### `(q/limit q n)` / `(q/offset q n)`

Set `LIMIT` / `OFFSET`.

#### `(q/first q)`

Run as a single row: the first match as an alist, or `#f` when nothing matches. Sets the limit to 1.

#### `(q/count q)`

Run as the integer number of matching rows (0 when none). Order, limit and offset are ignored.

```scheme
(q/run (q/count (q/limit (users/q) 5)))
;; SQL: SELECT COUNT(*) AS _count FROM users
```

#### `(q/then q proc)`

Post-process the final value: `proc` receives what the descriptor would otherwise return (row vector, row or `#f`, or count). Several `q/then` calls compose in order. Because the transformation travels with the descriptor, it also applies inside a batch.

```scheme
(q/run (q/then (q/count (users/q)) zero?))   ; => #t on an empty table

(q/run (q/then (users/q)
               (lambda (rows) (map (lambda (r) (alist-ref 'name r))
                                   (vector->list rows)))))
; => ("Alice" "Bob")
```

#### `(q/by-id q id)`

Shorthand for `(q/first (q/where q '(= id ?) id))`.

#### `(q/run q)`

Render and run a single descriptor with `db/query`, returning a vector of row alists (kebab-case keys), a single row or `#f` (`q/first`), or an integer (`q/count`), after any `q/then` procedures.

#### `(q/run-list qs)`

Run a list of descriptors and return a list of their results, in order. Every descriptor is rendered first, so a scope error in any of them aborts the call before anything is sent. The statements then go to the database in a single `db/batch`, which is one round trip on backends with native batching (rqlite) and one query per statement elsewhere (SQLite).

#### `(q/run-all q ...)`

Like `q/run-list`, but takes the descriptors as arguments and returns their results as multiple values.

```scheme
(receive (user posts unread)
    (q/run-all (q/by-id (users/q) uid)
               (q/limit (q/where (posts/q) '(= published ?) 1) 10)
               (q/count (q/where (notifications/q) '(= user-id ?) uid)))
  ...)   ; one HTTP request on rqlite
```

### Migrating from 0.0.12

Version 0.0.13 removed the immediate read functions in favour of descriptors:

| 0.0.12 | 0.0.13 |
| --- | --- |
| `(users/all)` | `(q/run (users/q))` |
| `(users/where c v ...)` | `(q/run (q/where (users/q) c v ...))` |
| `(users/find c v)` | `(q/run (q/first (q/where (users/q) c v)))` |
| `(users/find '(= id ?) (list id))` | `(q/run (q/by-id (users/q) id))` |
| `(users/count)` | `(q/run (q/count (users/q)))` |
| `limit:` / `order:` / `offset:` | `q/limit` / `q/order` / `q/offset` |
| `(users/posts user)` | `(q/run (users/posts/q user))` |
| `(posts/users post)` | `(q/run (posts/users/q post))` |

Note that `where`/`find`/`count` took their values as a list; `q/where` takes them as separate arguments.

## API: Lifecycle Hooks (model/hook)

Lifecycle hooks are additive, multi-subscriber callbacks attached to a model.
Unlike a model scope, which is a single security policy, any number of hooks may
be registered per event, by any module that can call `(users/hooks)`.

The six events are `before-create`, `after-create`, `before-save`, `after-save`,
`before-delete` and `after-delete`.

**Hooks do not cascade.** Unlike ActiveRecord, where `before_save` also runs on
create, an event here fires only for its own operation. To run one body on both
paths, list both events.

`before-*` hooks are a left fold: each is `row -> row`, they run in registration
order, and each receives the previous one's output. A `before-*` hook that
returns a non-list signals an error. `after-*` hooks are observers: they receive
the persisted row and their return values are discarded.

A hook that calls `error` aborts the operation.

Ordering per operation:

```
create:  before-create hooks (in order)
           -> scope write callback
           -> INSERT
           -> re-fetch (scoped)
           -> after-create hooks       [skipped + warning if re-fetch is #f]

save:    before-save hooks (in order)
           -> scope write callback
           -> UPDATE ... WHERE pk AND scope
           -> re-fetch (scoped)
           -> after-save hooks         [skipped + warning if re-fetch is #f]

delete:  before-delete hooks (in order)
           -> DELETE ... WHERE pk AND scope   [pk taken from the hooks' result]
           -> after-delete hooks       [always run; delete always returns #t]
```

Because there are no transactions and the scope check rides in the `WHERE`
clause, a `before-*` hook's side effects have already happened even when the
write ultimately affects zero rows.

#### `(model/hook table (event row) body ...)`

Macro. Register a hook on `table` for `event`, binding the incoming row alist to
`row` in `body`. The head may also be `((event ...) row)`, which registers one
shared closure against each listed event.

```scheme
(model/hook users (before-create row)
  (alist-update 'slug (slugify (alist-ref 'name row)) row))

(model/hook users (after-delete row)
  (audit-log! 'deleted row))

(model/hook users ((before-create before-save) row)
  (normalize-email row))
```

Expands to a `model-hooks-add!` call per event against `(table/hooks)`. The
event symbol cannot be checked at expansion time, so an unknown event is
reported by `model-hooks-add!` when the registering module is loaded.

Registration happens as a side effect of loading the form, and `define-model`
binds a fresh registry, so reloading a file containing both a `define-model` and
its `model/hook` forms re-registers each hook exactly once rather than
accumulating duplicates.

#### `(make-model-hooks)`

Return a new, empty `model-hooks` registry. `define-model` calls this for you;
it is exported mainly for testing.

#### `(model-hooks? x)`

Return `#t` if `x` is a `model-hooks` registry.

#### `(model-hooks-add! hooks event proc)`

Append `proc` to `event`'s hook list. Appending means registration order is run
order. Signals an error for an invalid registry, an unknown event, or a
non-procedure.

#### `(model-hooks-ref hooks event)`

Return the list of procedures registered for `event`, or `'()`.

#### `(model-hooks-clear! hooks [event])`

Remove the hooks for `event`, or all hooks when `event` is omitted. Primarily
useful for test isolation, since a model's registry is global mutable state
shared across a test file.

#### `(model-hook-events)`

Return the list of supported event symbols.

#### `(model-hook-event? event)`

Return `#t` if `event` is one of the supported events.

#### `(run-before-hooks hooks event row)`

Fold `row` through `event`'s hooks and return the result. When `hooks` is `#f`,
returns `row` unchanged. Signals an error if any hook returns a non-list.

#### `(run-after-hooks hooks event row)`

Run `event`'s hooks for effect and return `row`. When `row` is `#f`, the hooks
are skipped and a warning is logged, since that indicates a write that landed
outside the model's scope. When `hooks` is `#f`, this is a no-op.

## API: Relationships (model/has-many)

#### `(model/has-many parent child)`

Macro. Declare a has-many relationship between two existing models. Assumes the convention that the child table has a `<singular-parent>-id` foreign key column (e.g. `posts.user_id` → `users.id`).

```scheme
(define-model users)
(define-model posts)
(model/has-many users posts)   ; posts.user_id -> users.id
```

This generates three functions:

#### `(users/posts/q parent-row)`

Return a query descriptor for the child rows belonging to `parent-row`. Refine it with the `q/` builders and run it with `q/run`, or batch it with `q/run-all`.

```scheme
(let ((user (q/run (q/by-id (users/q) 1))))
  (q/run (users/posts/q user)))
;; SQL: SELECT id, user_id, title FROM posts WHERE (user_id = ?)

;; refined with q/
(let ((user (q/run (q/by-id (users/q) 1))))
  (q/run (q/limit (q/where (users/posts/q user) '(= published ?) 1) 5)))
;; SQL: SELECT ... FROM posts WHERE ((user_id = ?) AND (published = ?)) LIMIT 5
```

#### `(posts/users/q child-row)`

Return a `q/first` descriptor for the parent row of `child-row`, so it runs to the parent alist or `#f`. If the child's foreign key is missing or NULL, the result is still a descriptor (one that matches nothing), so it can be batched like any other.

```scheme
(let ((post (q/run (q/by-id (posts/q) 1))))
  (q/run (posts/users/q post)))   ; => ((id . 1) (name . "Alice") ...)
;; SQL: SELECT id, name, email FROM users WHERE (id = ?) LIMIT 1
```

#### `(users/add-posts parent-row child-row)`

Associate `child-row` with `parent-row` by setting the foreign key, and save the child (issuing the same `UPDATE posts SET ... WHERE (id = ?)` as `posts/save`).

## API: Migrations

A migration registers an up procedure and a down procedure under a name. Migrations are applied in registration order; the current version is tracked in a `schema_migrations` table that is created automatically.

#### `(model/migration name up-proc down-proc)`

Register a migration. `name` is a string (e.g. `"001-create-users"`); `up-proc` and `down-proc` are zero-argument thunks.

```scheme
(model/migration "001-create-users"
  (lambda ()
    (model/schema/create-table 'users
      '(id integer (primary-key #t) (autoincrement #t))
      '(name text (not-null #t))
      '(email text (unique #t))
      '(created-at datetime (default CURRENT_TIMESTAMP))
      '(updated-at datetime (default CURRENT_TIMESTAMP))))
  (lambda ()
    (model/schema/drop-table 'users)))

(model/migration "002-add-status-to-users"
  (lambda () (model/schema/add-columns 'users '(status text (default "active"))))
  (lambda () (model/schema/drop-columns 'users 'status)))
```

#### `(model/migrate [target-version])`

Apply migrations. With no argument, migrate up to the latest registered migration. With a target name, migrate up **or** down to that version, applying the necessary up/down procedures in order.

```scheme
(model/migrate)                    ; up to latest
(model/migrate "001-create-users") ; up or down to this version
```

#### `(model/rollback-all!)`

Roll back every applied migration, returning the schema to a clean state.

### Running Migrations from the CLI

The egg installs an `orm-migrate` program that runs migrations without a driver script. Point it at a migrations file — a plain Scheme file containing `(model/migration ...)` forms (no imports needed; `orm` is already in scope) — and choose the backend at runtime.

```bash
# Apply all migrations up to the latest
orm-migrate -b sqlite -path myapp.db -f migrations.scm

# Migrate up or down to a specific version
orm-migrate -b sqlite -path myapp.db -f migrations.scm -m 001-create-users

# Roll everything back to a clean state
orm-migrate -b sqlite -path myapp.db -f migrations.scm --rollback

# rqlite: -path is the HTTP connection string (keep credentials off disk)
orm-migrate -b rqlite -path "https://user:pass@host:4001" -f migrations.scm
```

| Flag | Description |
| --- | --- |
| `-b`, `--backend` | Backend to use: `sqlite` or `rqlite` (required) |
| `-path`, `--path` | Database path / connection string (required) |
| `-f`, `--file` | Migrations file with `(model/migration ...)` forms (required) |
| `-m`, `--migration` | Target version; migrates up or down to it (default: latest) |
| `--rollback` | Roll back all migrations |
| `-h`, `--help` | Show usage |

The chosen backend egg (`orm-db-sqlite` or `orm-db-rqlite`) is imported dynamically at runtime, so it must be installed, but the `orm` egg keeps no static dependency on either.

## API: Schema Helpers

These helpers generate and run DDL; they are normally called from inside migration thunks.

#### `(model/schema/create-table table-name column-spec ...)`

Create a table. Each `column-spec` is `(name type option ...)`.

```scheme
(model/schema/create-table 'posts
  '(id integer (primary-key #t) (autoincrement #t))
  '(user-id integer (foreign-key users id))
  '(title text (not-null #t))
  '(body text)
  '(published boolean (default #f))
  '(created-at datetime (default CURRENT_TIMESTAMP)))
```

#### `(model/schema/drop-table table-name)`

Drop a table.

#### `(model/schema/add-columns table-name column-spec ...)`

Add one or more columns. Honors the same options as `create-table`.

```scheme
(model/schema/add-columns 'posts
  '(slug text)
  '(view-count integer (default 0)))
```

#### `(model/schema/drop-columns table-name column-name ...)`

Drop one or more columns (subject to the backend's `ALTER TABLE` support).

#### `(column-spec->sql spec [alter?])`

Render a single column spec to its SQL fragment. Exposed for reuse; `create-table` and `add-columns` build on it.

### Column Options

| Option | Example | Description |
| --- | --- | --- |
| `primary-key` | `(primary-key #t)` | Mark as primary key |
| `autoincrement` | `(autoincrement #t)` | Auto-increment (integers) |
| `not-null` | `(not-null #t)` | NOT NULL constraint |
| `unique` | `(unique #t)` | UNIQUE constraint |
| `default` | `(default 0)` | Default value |
| `foreign-key` | `(foreign-key users id)` | Foreign key reference |

### Column Types

Supported types: `integer`, `text`, `string`, `real`, `float`, `blob`, `datetime`, `boolean`.

## API: Helper Functions

#### `(row-ref/default key row [default])`

Read `key` from `row`, returning `default` when the value is SQL NULL (the symbol `null`). Signals an error if the key is absent. `default` is `#f` when omitted.

```scheme
(row-ref/default 'name user)            ; => "Alice"
(row-ref/default 'nickname user "N/A")  ; => "N/A" if NULL
```

#### `(row-metadata row [default])`

For a row with a `metadata` TEXT column holding an s-expression alist, parse and return that alist (or `default`, default `'()`, when NULL or unparseable).

```scheme
(row-metadata user)   ; => ((theme . "dark") (language . "en"))
```

#### `(row-metadata-set! row alist)`

Write `alist` to the row's `metadata` column and return the updated row alist.

```scheme
(row-metadata-set! user '((theme . "light")))
```

#### `(symbol->db-column sym)` / `(db-column->symbol sym-or-string)`

Convert names between Scheme kebab-case and SQL snake_case.

```scheme
(symbol->db-column 'created-at)   ; => created_at
(db-column->symbol 'created_at)   ; => created-at
(db-column->symbol "created_at")  ; => created-at
```

The module also exports the lower-level helpers `load-table-metadata`, `register-model!`, `get-model-metadata`, `convert-result-keys`, `convert-results-vector`, `get-primary-key-columns`, `build-pk-where`, and `map-field-names->columns`, used internally by the generated functions.

## API: Testing (orm-test)

The `orm-test` module — bundled in the `orm` egg, no separate install — provides a mock backend for testing code that uses `orm-db` without a real database.

#### `(make-mock-backend)`

Returns two values: a backend alist (compatible with `db/backend`) and a `spy` procedure for inspecting and controlling the mock.

```scheme
(import orm-db orm-test)

(receive (backend spy) (make-mock-backend)
  (db/backend backend)
  (db/path "ignored")
  (db/connect)

  ;; Configure responses
  (spy 'on-query (list (vector '((id . 1) (name . "Alice")))))

  (q/run (users/q))  ; => #(((id . 1) (name . "Alice")))
  (spy 'queries))    ; => ((<ssql form> ()))
```

The `spy` procedure responds to these messages:

| Message | Arguments | Description |
| --- | --- | --- |
| `queries` | none | List of `(sql params)` pairs from all queries |
| `executions` | none | List of `(sql params out-key)` from all executions |
| `batches` | none | List of statement lists, one per `db/batch` call (each statement is `(sql . params)`). Batched statements are also answered by the query handler and recorded in `queries`, so a test can assert "3 reads, 1 batch" |
| `on-query` | responses-or-proc | Set query responses: a list (consumed in order, last repeats) or a `(lambda (sql params) ...)` |
| `on-execute` | responses-or-proc | Set execute responses: a list or a `(lambda (sql params out-key) ...)` |
| `reset!` | none | Clear recorded queries, executions and batches |

```scheme
;; Static list of responses (last item repeats forever)
(spy 'on-query (list
  (vector '((id . 1) (name . "Alice")))   ; first query
  (vector)))                               ; all subsequent queries

;; Dynamic responses
(spy 'on-query (lambda (sql params)
  (if (string-contains sql "users")
      (vector '((id . 1) (name . "Alice")))
      (vector))))
```

## Complete Example

```scheme
(import orm-db orm-db-sqlite orm)

;; 1. Connect
(db/backend (sqlite3-backend))
(db/path "blog.db")
(db/connect)

;; 2. Migrate the schema
(model/migration "001-init"
  (lambda ()
    (model/schema/create-table 'users
      '(id integer (primary-key #t) (autoincrement #t))
      '(name text (not-null #t))
      '(updated-at datetime (default CURRENT_TIMESTAMP)))
    (model/schema/create-table 'posts
      '(id integer (primary-key #t) (autoincrement #t))
      '(user-id integer (foreign-key users id))
      '(title text (not-null #t))
      '(updated-at datetime (default CURRENT_TIMESTAMP))))
  (lambda ()
    (model/schema/drop-table 'posts)
    (model/schema/drop-table 'users)))

(model/migrate)

;; 3. Define models and a relationship
(define-model users)
(define-model posts)
(model/has-many users posts)

;; 4. Use them
(define alice (users/create '((name . "Alice"))))
(users/add-posts alice (posts/create `((title . "Hello") (user-id . ,(alist-ref 'id alice)))))

(q/run (users/posts/q alice))   ; => #(((id . 1) (title . "Hello") ...))

;; several independent reads in one batch
(receive (n latest)
    (q/run-all (q/count (users/q))
               (q/first (q/order (posts/q) '(desc id))))
  (print n " users, latest post: " (alist-ref 'title latest)))

(db/close)
```

## License

Copyright © 2026 Rolando Abarca. Released under the BSD-3-Clause license.

## Repository

Part of the [chicken-orm-egg](https://github.com/schematra/chicken-orm-egg) project.
