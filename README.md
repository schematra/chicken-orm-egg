# ORM Egg

A simple ORM (Object-Relational Mapping) for CHICKEN Scheme with support for models, migrations, and relationships.

## Eggs

This repository contains three eggs:

- **orm** - The ORM itself (models, migrations, relationships). Bundles three modules:
  - `orm` - the ORM (models, migrations, relationships)
  - `orm-db` - abstract database interface with pluggable backends
  - `orm-test` - mock backend for testing ORM code without a real database
- **orm-db-sqlite** - SQLite3 backend
- **orm-db-rqlite** - rqlite (HTTP-based distributed SQLite) backend

The backends are separate eggs because each pulls heavy, mutually-exclusive
dependencies — install only the one you need. Module names are unchanged:
`(import orm-db)` and `(import orm-test)` work as before.

## Installation

```scheme
chicken-install orm
chicken-install orm-db-sqlite  ; if using SQLite
chicken-install orm-db-rqlite  ; if using rqlite
```

## Quick Start

```scheme
(import orm-db orm-db-sqlite orm)

;; Configure and connect to database
(db/backend (sqlite3-backend))
(db/path "myapp.db")
(db/connect)

;; Define a model (table must already exist)
(define-model users)

;; Query all users
(q/run (users/q))  ; => #(((id . 1) (name . "Alice") ...) ...)

;; Find a specific user
(q/run (q/by-id (users/q) 1))  ; => ((id . 1) (name . "Alice") ...)
```

## Database Setup

### Configuring the Backend

```scheme
(import orm-db orm-db-sqlite)

;; Set the backend (must be done before connecting)
(db/backend (sqlite3-backend))

;; Set the database path
(db/path "path/to/database.db")

;; Connect
(db/connect)

;; When done, close the connection
(db/close)
```

## Defining Models

The `define-model` macro creates a model bound to an existing database table. It automatically introspects the table schema and generates CRUD functions.

```scheme
(define-model users)
```

This generates the following functions:

| Function | Description |
|----------|-------------|
| `users/q` | Start a query descriptor (see [Querying](#querying)) |
| `users/create` | Insert a new row |
| `users/save` | Update an existing row |
| `users/update` | Find and update by ID |
| `users/delete` | Delete a row |
| `users/columns` | Get column metadata |
| `users/pkey` | Get primary key column(s) |
| `users/hooks` | Get the model's lifecycle hook registry |

### Mandatory Model Scopes

A model may declare an application-defined scope that the ORM automatically
applies to every generated CRUD operation:

```scheme
(define current-account-id (make-parameter #f))

(define account-scope
  (make-model-scope
   ;; Return a mandatory condition and its placeholder values.
   (lambda ()
     (let ((account-id (current-account-id)))
       (unless account-id (error "account scope required"))
       (values '(= account-id ?) (list account-id))))
   ;; Prepare rows before create/save (update delegates to save).
   (lambda (row)
     (alist-update 'account-id (current-account-id) row))))

(define-model invoices scope: account-scope)
```

The scope condition is ANDed into every `users/q` read when the descriptor
runs (not when it is built), ahead of the caller's conditions. It is also included directly in the `WHERE` clause for
`save`, `update`, and `delete`, so a primary key from another scope cannot be
modified. The write callback runs before `create` and `save`, allowing the
application to stamp or validate ownership fields.

Scope callbacks should fail when required context is missing. A configured
scope that returns no condition is rejected rather than falling back to an
unscoped query. Direct `db/query` and `db/execute` calls bypass model scopes and
remain the application's responsibility.

### Lifecycle Hooks

Where a scope is a single security policy, lifecycle hooks are ordinary
application behavior: derive a slug before an insert, bust a cache after an
update, write an audit row after a delete. Any number of hooks may be
registered per event, and any module holding `(users/hooks)` can add one.

```scheme
(define-model users)

(model/hook users (before-create row)
  (alist-update 'slug (slugify (alist-ref 'name row)) row))

(model/hook users (after-delete row)
  (audit-log! 'deleted row))

;; one body, several events
(model/hook users ((before-create before-save) row)
  (normalize-email row))
```

There are six events:

| Event | Fires on |
|-------|----------|
| `before-create` / `after-create` | `users/create` |
| `before-save` / `after-save` | `users/save` and `users/update` |
| `before-delete` / `after-delete` | `users/delete` |

**Hooks do not cascade.** This is the biggest difference from ActiveRecord: in
Rails, `before_save` also runs on create. Here it does not. `users/create`
fires *only* the create hooks. If you want a hook on both paths, list both
events explicitly, as in the third example above. `users/update` delegates to
`users/save`, so it fires the save hooks exactly once.

`before-*` hooks are a **left fold**: each one is `row -> row`, they run in
registration order, and each is fed the previous one's output. Returning
something that is not an alist is an error. `after-*` hooks are **observers**:
they receive the persisted row and their return values are ignored, so a hook
that forgets to return the row cannot corrupt what `create` or `save` hands
back.

Hooks run **before** the scope's write procedure. The scope is the security
boundary and must be the last writer, so a `before-create` hook can never
clobber a scope-injected `account-id`. A hook that needs that value should read
the application parameter the scope reads, rather than the row.

A hook that calls `error` aborts the whole operation. There is no separate
"cancel" protocol.

Four sharp edges worth knowing:

1. **`before-*` hooks fire even when the write affects zero rows.** There are no
   transactions, and the scope check rides in the `UPDATE`'s `WHERE`, so a
   `before-save` side effect has already happened by the time `save` returns `#f`.
2. **`after-*` hooks are skipped when the post-write re-fetch returns `#f`**,
   which is what an out-of-scope write looks like. The ORM logs a warning on
   that path rather than failing silently.
3. **`after-delete` fires even on a no-op delete.** `users/delete` ignores
   `rows_affected` and always returns `#t`.
4. **`before-delete` is a fold like the others**, so a hook that rewrites `id`
   will delete a *different row*: the primary key for the `DELETE` comes from
   whatever the hooks returned.

### Naming Conventions

The ORM automatically converts between Scheme's kebab-case and SQL's snake_case:

- Table name `user-sessions` maps to `user_sessions`
- Column `created-at` maps to `created_at`
- Results are returned with kebab-case keys

## Querying

Reads are values. `users/q` returns a **query descriptor**; the `q/` functions
refine it and return a new descriptor, and nothing touches the database until a
runner executes it. That lets independent reads be sent together: on rqlite,
`q/run-all` costs one HTTP round trip instead of one per query.

```scheme
(q/run (users/q))  ; => #(((id . 1) (name . "Alice")) ((id . 2) (name . "Bob")))
```

Every builder takes the descriptor first, so a threading macro such as `->`
(from `clojurist`, or your own) reads naturally. The ORM itself does not depend
on one: nested calls work the same.

```scheme
(q/run (-> (users/q)
           (q/where '(= status ?) "active")
           (q/order '(desc created-at))
           (q/limit 10)))

;; the same thing, without ->
(q/run (q/limit (q/order (q/where (users/q) '(= status ?) "active")
                         '(desc created-at))
                10))
```

### Builders

| Function | Description |
|----------|-------------|
| `(q/where q cond val ...)` | Add a condition; values follow it. Several calls AND together, values in call order |
| `(q/order q order)` | `field`, `(asc field)` or `(desc field)`; kebab-case fields are converted |
| `(q/limit q n)` | `LIMIT n` |
| `(q/offset q n)` | `OFFSET n` |
| `(q/first q)` | Run to the first row (an alist) or `#f` |
| `(q/count q)` | Run to the integer count of matching rows (ignores order, limit, offset) |
| `(q/by-id q id)` | Shorthand for `(q/first (q/where q '(= id ?) id))` |
| `(q/then q proc)` | Post-process the final value; several calls compose in order |

```scheme
;; Conditions
(q/where (users/q) '(= status ?) "active")
(q/where (users/q) '(and (= status ?) (> age ?)) "active" 18)
(-> (users/q) (q/where '(= status ?) "active") (q/where '(> age ?) 18)) ; same thing
(q/where (users/q) '(like name ?) "%alice%")
(q/where (users/q) '(is deleted-at ?) 'null)

;; A single row
(q/run (q/first (q/where (users/q) '(= email ?) "bob@example.com")))
; => ((id . 2) (name . "Bob") (email . "bob@example.com"))
(q/run (q/by-id (users/q) 999))  ; => #f

;; Counting
(q/run (q/count (users/q)))                                  ; => 42
(q/run (q/count (q/where (users/q) '(= status ?) "active"))) ; => 15

;; Post-processing
(q/run (q/then (users/q) (lambda (rows) (map (cut alist-ref 'name <>) (vector->list rows)))))
; => ("Alice" "Bob")
```

### Running

| Function | Description |
|----------|-------------|
| `(q/run q)` | Run one descriptor |
| `(q/run-all q ...)` | Run several in one batch, returning one value per descriptor |
| `(q/run-list qs)` | Same as `q/run-all`, but takes and returns a list |

```scheme
(receive (user posts unread)
    (q/run-all (q/by-id (users/q) uid)
               (-> (posts/q) (q/where '(= published ?) 1) (q/limit 10))
               (-> (notifications/q) (q/where '(= user-id ?) uid) (q/count)))
  ...)  ; one round trip on rqlite
```

Batches go through `db/batch`. The rqlite backend sends every statement in a
single request; SQLite (and any backend without native batching) runs them one
after the other, so the same code works everywhere.

The model scope is applied when a descriptor **runs**, not when it is built, so a
descriptor built outside a `parameterize` picks up the scope context at run time.
`q/run-list` renders every descriptor before sending anything: if one scope fails
closed, no statement is sent.

## Creating and Updating

### Create a New Row

```scheme
(users/create '((name . "Charlie") (email . "charlie@example.com")))
; => ((id . 3) (name . "Charlie") (email . "charlie@example.com") ...)
```

The `create` function returns the newly created row (fetched by rowid). It fires
`before-create` (before the scope's write procedure) and then `after-create`.
It does *not* fire the save hooks.

### Save (Update) an Existing Row

```scheme
(let ((user (q/run (q/by-id (users/q) 1))))
  ;; Modify the user
  (let ((updated-user (alist-update 'name "Alicia" user)))
    ;; Save changes
    (users/save updated-user)))
```

The `save` function:
- Updates based on primary key
- Automatically sets `updated_at` to `CURRENT_TIMESTAMP`
- Ignores `created-at` and `updated-at` in the input
- Returns the fresh row from the database
- Fires `before-save` (before the scope's write procedure) and then `after-save`

`users/update` delegates to `users/save`, so it fires the save hooks once, not
twice. If the scoped `UPDATE` matches no rows, `before-save` has already run but
`after-save` is skipped.

### Update by ID

```scheme
;; Convenience wrapper: look up by ID, apply updates, save
(users/update 1 '((name . "Alicia") (status . "inactive")))
; => ((id . 1) (name . "Alicia") (status . "inactive") ...)

;; Returns #f if ID not found
(users/update 999 '((name . "Nobody")))  ; => #f
```

## Deleting

```scheme
(let ((user (q/run (q/by-id (users/q) 1))))
  (users/delete user))  ; => #t
```

`delete` fires `before-delete` and then `after-delete`, both receiving the row
the before-hooks returned. It always returns `#t`, even when no row matched, so
`after-delete` fires on a no-op delete too.

## Migrations

The ORM includes a simple migration system for managing schema changes.

### Defining Migrations

```scheme
(model/migration "001-create-users"
  ;; Up migration
  (lambda ()
    (model/schema/create-table 'users
      '(id integer (primary-key #t) (autoincrement #t))
      '(name text (not-null #t))
      '(email text (unique #t))
      '(created-at datetime (default CURRENT_TIMESTAMP))
      '(updated-at datetime (default CURRENT_TIMESTAMP))))
  ;; Down migration
  (lambda ()
    (model/schema/drop-table 'users)))

(model/migration "002-add-status-to-users"
  (lambda ()
    (model/schema/add-columns 'users
      '(status text (default "active"))))
  (lambda ()
    (model/schema/drop-columns 'users 'status)))
```

### Running Migrations

```scheme
;; Run all pending migrations
(model/migrate)

;; Migrate to a specific version
(model/migrate "001-create-users")

;; Roll back all migrations
(model/rollback-all!)
```

### Running Migrations from the CLI

The `orm` egg installs an `orm-migrate` program that runs migrations without
writing a driver script. Point it at a migrations file — a plain Scheme file
containing `(model/migration ...)` forms (no imports needed; `orm` is in scope)
— and select the backend at runtime:

```sh
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

The backend egg (`orm-db-sqlite` or `orm-db-rqlite`) is imported dynamically, so
it must be installed, but the `orm` egg keeps no static dependency on either.

### Schema Helpers

```scheme
;; Create a table
(model/schema/create-table 'posts
  '(id integer (primary-key #t) (autoincrement #t))
  '(user-id integer (foreign-key users id))
  '(title text (not-null #t))
  '(body text)
  '(published boolean (default #f))
  '(created-at datetime (default CURRENT_TIMESTAMP)))

;; Drop a table
(model/schema/drop-table 'posts)

;; Add columns
(model/schema/add-columns 'posts
  '(slug text)
  '(view-count integer (default 0)))

;; Drop columns (limited SQLite support)
(model/schema/drop-columns 'posts 'slug 'view-count)
```

### Column Options

| Option | Example | Description |
|--------|---------|-------------|
| `primary-key` | `(primary-key #t)` | Mark as primary key |
| `autoincrement` | `(autoincrement #t)` | Auto-increment (integers) |
| `not-null` | `(not-null #t)` | NOT NULL constraint |
| `unique` | `(unique #t)` | UNIQUE constraint |
| `default` | `(default 0)` | Default value |
| `foreign-key` | `(foreign-key users id)` | Foreign key reference |

### Column Types

Supported types: `integer`, `text`, `string`, `real`, `float`, `blob`, `datetime`, `boolean`

## Relationships

### Has-Many Relationships

```scheme
(define-model users)
(define-model posts)

;; Define the relationship (posts.user_id -> users.id)
(model/has-many users posts)
```

This generates:

| Function | Description |
|----------|-------------|
| `(users/posts/q user)` | Descriptor for a user's posts |
| `(posts/users/q post)` | Descriptor for a post's user (runs to a row or `#f`) |
| `(users/add-posts user post)` | Associate a post with a user (a write, runs immediately) |

The read side returns descriptors, so they refine with `q/` and batch like any
other query:

```scheme
(let ((user (q/run (q/by-id (users/q) 1))))
  ;; All posts for a user
  (q/run (users/posts/q user))  ; => #(((id . 1) (title . "Post 1") ...) ...)

  ;; With additional conditions
  (q/run (-> (users/posts/q user)
             (q/where '(= published ?) 1)
             (q/order '(desc created-at))
             (q/limit 5))))

;; The user for a post
(let ((post (q/run (q/by-id (posts/q) 1))))
  (q/run (posts/users/q post)))  ; => ((id . 1) (name . "Alice") ...)
```

A post with a missing or NULL `user-id` still gets a descriptor from
`posts/users/q`; it matches nothing and runs to `#f`.

## Helper Functions

### row-ref/default

Get a value from a row, treating SQL NULL as a default:

```scheme
(let ((user (q/run (q/by-id (users/q) 1))))
  (row-ref/default 'name user)           ; => "Alice"
  (row-ref/default 'nickname user "N/A") ; => "N/A" if NULL
  (row-ref/default 'missing user))       ; => error: key doesn't exist
```

### row-metadata / row-metadata-set!

For tables with a `metadata` TEXT column storing s-expressions:

```scheme
;; Read metadata (returns alist, or default if NULL/invalid)
(let ((user (q/run (q/by-id (users/q) 1))))
  (row-metadata user))  ; => ((theme . "dark") (language . "en"))

;; Set metadata (returns updated row alist)
(let ((user (q/run (q/by-id (users/q) 1))))
  (row-metadata-set! user '((theme . "light"))))
```

### Name Conversion

```scheme
;; Scheme symbol to DB column (kebab-case -> snake_case)
(symbol->db-column 'created-at)  ; => created_at

;; DB column to Scheme symbol (snake_case -> kebab-case)
(db-column->symbol 'created_at)  ; => created-at
(db-column->symbol "created_at") ; => created-at
```

## Testing with orm-test

The `orm-test` module (bundled in the `orm` egg) provides a mock database backend for testing code that uses `orm-db` without requiring a real database connection. It's installed automatically with `orm`, no separate install needed.

### make-mock-backend

`make-mock-backend` returns two values: a backend (compatible with `db/backend`) and a spy procedure for inspecting and controlling the mock.

```scheme
(import orm-db orm-test)

(receive (backend spy) (make-mock-backend)
  ;; Use the mock backend instead of a real one
  (db/backend backend)
  (db/path "ignored")
  (db/connect)

  ;; Configure responses for queries
  (spy 'on-query (list (vector '((id . 1) (name . "Alice")))))

  ;; Now any query will return the configured response
  (q/run (users/q))  ; => #(((id . 1) (name . "Alice")))

  ;; Inspect what SQL was executed
  (spy 'queries)  ; => (((select ...) ()))
  )
```

### Spy Messages

| Message | Arguments | Description |
|---------|-----------|-------------|
| `queries` | none | Returns list of `(sql params)` pairs from all queries |
| `executions` | none | Returns list of `(sql params out-key)` from all executions |
| `batches` | none | Returns list of batches, each the list of `(sql . params)` statements passed to `db/batch` |
| `on-query` | responses-or-proc | Set query responses: a list (consumed in order, last repeats) or a `(lambda (sql params) ...)` |
| `on-execute` | responses-or-proc | Set execute responses: a list or a `(lambda (sql params out-key) ...)` |
| `reset!` | none | Clear recorded queries, executions and batches |

The mock implements native batching: each `db/batch` call (and so each
`q/run-all`) is recorded once in `batches`, and every statement in it is also
answered by the `on-query` handler and logged in `queries`. That makes "these
three reads cost one round trip" easy to assert:

```scheme
(q/run-all (users/q) (q/count (posts/q)) (q/by-id (users/q) 1))
(length (spy 'batches))        ; => 1
(length (car (spy 'batches)))  ; => 3
```

### Configuring Responses

Responses can be a list (each call consumes the next item; the last item repeats forever) or a procedure for dynamic responses:

```scheme
;; Static list of responses
(spy 'on-query (list
  (vector '((id . 1) (name . "Alice")))   ; first query returns this
  (vector)))                                ; all subsequent queries return empty

;; Dynamic responses
(spy 'on-query (lambda (sql params)
  (if (string-contains sql "users")
      (vector '((id . 1) (name . "Alice")))
      (vector))))
```

## History

### v0.0.13

**Breaking:** the generated read functions are gone. `define-model` no longer
generates `users/all`, `users/find`, `users/where` or `users/count`, and
`model/has-many` reads gained a `/q` suffix. There is no deprecation release.

- `define-model` generates `(users/q)`, which returns a query descriptor. The new
  `q/` library builds descriptors (`q/where`, `q/order`, `q/limit`, `q/offset`,
  `q/first`, `q/count`, `q/by-id`, `q/then`) and runs them (`q/run`, `q/run-all`,
  `q/run-list`).
- `q/run-all` / `q/run-list` send several reads in one `db/batch`: one HTTP round
  trip on rqlite, sequential everywhere else.
- `orm-db` adds `db/batch` and an optional `batch` backend entry, with a
  sequential fallback through `query`. `orm-db-rqlite` (now 0.0.13, to match the
  release tag) implements it natively, sending every statement in one request.
  `orm-db-sqlite` is unchanged and stays at 0.0.10.
- The model scope is applied when a descriptor runs, last, exactly as before.
- `orm-test`'s mock backend supports batching and records a `batches` spy log.

Migrating:

| Before | After |
|--------|-------|
| `(users/all)` | `(q/run (users/q))` |
| `(users/all limit: 10 order: 'name)` | `(q/run (-> (users/q) (q/order 'name) (q/limit 10)))` |
| `(users/where c '(v ...))` | `(q/run (q/where (users/q) c v ...))` |
| `(users/where c vs offset: 20)` | `(q/run (-> (users/q) (q/where c v ...) (q/offset 20)))` |
| `(users/find c '(v ...))` | `(q/run (-> (users/q) (q/where c v ...) (q/first)))` |
| `(users/find '(= id ?) (list id))` | `(q/run (q/by-id (users/q) id))` |
| `(users/count)` | `(q/run (q/count (users/q)))` |
| `(users/count c '(v ...))` | `(q/run (q/count (q/where (users/q) c v ...)))` |
| `(users/posts user)` | `(q/run (users/posts/q user))` |
| `(users/posts user c '(v ...) limit: 5)` | `(q/run (-> (users/posts/q user) (q/where c v ...) (q/limit 5)))` |
| `(posts/users post)` | `(q/run (posts/users/q post))` |

Note that `q/where` takes its values as rest arguments, not as a list.

### v0.0.12

- Added lifecycle hooks: `(model/hook users (before-create row) ...)` registers
  additive, multi-subscriber callbacks on a model.
- Six events: `before-create`/`after-create`, `before-save`/`after-save`,
  `before-delete`/`after-delete`. Hooks do **not** cascade, so `create` fires only
  the create hooks (unlike ActiveRecord). A multi-event head registers one closure
  against several events.
- `before-*` hooks are a left fold (`row -> row`, in registration order);
  `after-*` hooks are observers whose return values are ignored.
- Hooks run before the scope's write procedure, so a hook can never clobber a
  scope-injected column.
- `define-model` now also generates `(users/hooks)`, which exposes the registry so
  another module can register hooks.
- New exports: `make-model-hooks`, `model-hooks?`, `model-hooks-add!`,
  `model-hooks-ref`, `model-hooks-clear!`, `model-hook-event?`,
  `model-hook-events`, `run-before-hooks`, `run-after-hooks`, `model/hook`.
- Models that register no hooks are unchanged.

### v0.0.11

- Added mandatory model scopes: `(define-model name scope: my-scope)` attaches an
  application-defined policy that the ORM applies to every generated CRUD function.
- New exports: `make-model-scope`, `model-scope?`, `apply-model-scope-condition`,
  `apply-model-scope-write`.
- The scope condition is combined into the same `WHERE` clause used by `save`,
  `update`, and `delete`, so a primary key from another scope cannot be mutated.
- The optional write callback runs before `create` and `save`, letting the
  application stamp or validate ownership fields.
- A configured scope that returns no condition is rejected rather than silently
  falling back to an unscoped query.
- Models without `scope:` are unchanged.

## License

BSD-3-Clause
