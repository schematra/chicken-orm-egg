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
(users/all)                    ; => #(((id . 1) (name . "Alice") ...) ...)
(users/find '(= id ?) '(1))    ; => ((id . 1) (name . "Alice") ...)
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

The `orm-db` module defines a backend-agnostic interface using CHICKEN parameters. A backend is an alist mapping the symbols `connect`, `close`, `query`, and `execute` to procedures; the backend eggs provide constructors (`sqlite3-backend`, `rqlite-backend`) that return such an alist.

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
any caller condition for `all`, `find`, `where`, and `count`, and includes it in
the same SQL `WHERE` for `save`, `update`, and `delete`. This makes scoped writes
atomic rather than a check followed by an unscoped primary-key mutation.

The optional write callback receives and returns a row alist. It runs before
`create` and `save`; `update` delegates to scoped `find` and `save`. Use it to
stamp or validate fields required by the scope. If omitted, it defaults to the
identity function.

Scope callbacks should signal an error when required context is unavailable.
A configured scope that returns `#f` as its condition is rejected. Raw
`db/query` and `db/execute` calls are not model operations and bypass scopes.

The model's `before-*` lifecycle hooks run *before* the scope's write callback,
so the scope is always the last writer and a hook cannot overwrite a
scope-injected column. See "API: Lifecycle Hooks" below.

For a model named `users`, the generated functions are listed below. Each example shows the SQL that is produced (the SQLite dialect; rqlite renders identically). Assume `users` has columns `id`, `name`, `email`.

#### `(users/all #!key limit order offset)`

Return all rows as a vector of alists.

```scheme
(users/all)
;; SQL: SELECT id, name, email FROM users

(users/all limit: 10)
;; SQL: SELECT id, name, email FROM users LIMIT 10

(users/all order: 'name)               ; ascending
;; SQL: SELECT id, name, email FROM users ORDER BY name

(users/all order: '(desc created-at))  ; descending
;; SQL: SELECT id, name, email FROM users ORDER BY created_at DESC
```

The column list comes from the introspected schema, and kebab-case names in `order` are converted to snake_case.

#### `(users/find [conditions] [values] #!key order)`

Return a single row (alist) matching `conditions`, or `#f` if none. `conditions` is an `ssql` WHERE form with `?` placeholders, `values` the bound values. `find` is just `where` with `limit: 1`.

```scheme
(users/find '(= id ?) '(1))
;; SQL: SELECT id, name, email FROM users WHERE (id = ?) LIMIT 1

(users/find '(= email ?) '("bob@example.com"))
;; SQL: SELECT id, name, email FROM users WHERE (email = ?) LIMIT 1

(users/find '(= id ?) '(999))   ; => #f
```

#### `(users/where [conditions] [values] #!key limit order offset)`

Return all rows matching `conditions` as a vector of alists.

```scheme
(users/where '(= status ?) '("active"))
;; SQL: SELECT id, name, email, status FROM users WHERE (status = ?)

(users/where '(and (= status ?) (> age ?)) '("active" 18))
;; SQL: SELECT ... FROM users WHERE ((status = ?) AND (age > ?))

(users/where '(>= age ?) '(21))
;; SQL: SELECT ... FROM users WHERE (age >= ?)

(users/where '(like name ?) '("%alice%"))
;; SQL: SELECT ... FROM users WHERE (name LIKE ?)

(users/where '(is deleted-at ?) '(null))
;; SQL: SELECT ... FROM users WHERE (deleted_at IS ?)

(users/where '(= status ?) '("active") limit: 10 order: '(desc created-at))
;; SQL: SELECT ... FROM users WHERE (status = ?) ORDER BY created_at DESC LIMIT 10
```

Comparison operators: `=`, `<>`, `<`, `>`, `<=`, `>=`, `like`, `is`. The `conditions` form is an `ssql` expression; `?` placeholders are bound positionally from `values`.

#### `(users/count [conditions] [values])`

Return the number of matching rows (all rows if no conditions).

```scheme
(users/count)                       ; => 42
;; SQL: SELECT COUNT(*) AS _count FROM users

(users/count '(= status ?) '("active"))  ; => 15
;; SQL: SELECT COUNT(*) AS _count FROM users WHERE (status = ?)
```

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
(let* ((user (users/find '(= id ?) '(1)))
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
(let ((user (users/find '(= id ?) '(1))))
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

#### `(users/posts parent-row [conditions] [values] #!key limit order offset)`

Return all child rows belonging to `parent-row`, optionally further filtered.

```scheme
(let ((user (users/find '(= id ?) '(1))))
  (users/posts user))
;; SQL: SELECT id, user_id, title FROM posts WHERE (user_id = ?)

;; with extra conditions
(let ((user (users/find '(= id ?) '(1))))
  (users/posts user '(= published ?) '(#t)))
;; SQL: SELECT ... FROM posts WHERE ((user_id = ?) AND (published = ?))
```

#### `(posts/users child-row)`

Return the parent row for `child-row`.

```scheme
(let ((post (posts/find '(= id ?) '(1))))
  (posts/users post))   ; => ((id . 1) (name . "Alice") ...)
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

  (users/all)        ; => #(((id . 1) (name . "Alice")))
  (spy 'queries))    ; => (("SELECT ..." ()))
```

The `spy` procedure responds to these messages:

| Message | Arguments | Description |
| --- | --- | --- |
| `queries` | none | List of `(sql params)` pairs from all queries |
| `executions` | none | List of `(sql params out-key)` from all executions |
| `on-query` | responses-or-proc | Set query responses: a list (consumed in order, last repeats) or a `(lambda (sql params) ...)` |
| `on-execute` | responses-or-proc | Set execute responses: a list or a `(lambda (sql params out-key) ...)` |
| `reset!` | none | Clear recorded queries and executions |

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

(users/posts alice)   ; => #(((id . 1) (title . "Hello") ...))

(db/close)
```

## License

Copyright © 2026 Rolando Abarca. Released under the BSD-3-Clause license.

## Repository

Part of the [chicken-orm-egg](https://github.com/schematra/chicken-orm-egg) project.
