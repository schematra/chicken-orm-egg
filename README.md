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
(users/all)  ; => #(((id . 1) (name . "Alice") ...) ...)

;; Find a specific user
(users/find '(= id ?) '(1))  ; => ((id . 1) (name . "Alice") ...)
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
| `users/all` | Get all rows |
| `users/find` | Find a single row |
| `users/where` | Query with conditions |
| `users/count` | Count matching rows |
| `users/create` | Insert a new row |
| `users/save` | Update an existing row |
| `users/update` | Find and update by ID |
| `users/delete` | Delete a row |
| `users/columns` | Get column metadata |
| `users/pkey` | Get primary key column(s) |

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

The scope condition is combined before caller conditions for `all`, `find`,
`where`, and `count`. It is also included directly in the `WHERE` clause for
`save`, `update`, and `delete`, so a primary key from another scope cannot be
modified. The write callback runs before `create` and `save`, allowing the
application to stamp or validate ownership fields.

Scope callbacks should fail when required context is missing. A configured
scope that returns no condition is rejected rather than falling back to an
unscoped query. Direct `db/query` and `db/execute` calls bypass model scopes and
remain the application's responsibility.

### Naming Conventions

The ORM automatically converts between Scheme's kebab-case and SQL's snake_case:

- Table name `user-sessions` maps to `user_sessions`
- Column `created-at` maps to `created_at`
- Results are returned with kebab-case keys

## Querying

### Get All Rows

```scheme
;; Get all users
(users/all)  ; => #(((id . 1) (name . "Alice")) ((id . 2) (name . "Bob")))

;; With limit
(users/all limit: 10)

;; With ordering
(users/all order: 'name)              ; ascending by name
(users/all order: '(desc created-at)) ; descending by created_at
```

### Find a Single Row

```scheme
;; Find by condition (returns single alist or #f)
(users/find '(= id ?) '(1))
; => ((id . 1) (name . "Alice") (email . "alice@example.com"))

(users/find '(= email ?) '("bob@example.com"))
; => ((id . 2) (name . "Bob") (email . "bob@example.com"))

;; Returns #f if not found
(users/find '(= id ?) '(999))  ; => #f
```

### Query with Conditions

```scheme
;; Basic equality
(users/where '(= status ?) '("active"))

;; Multiple conditions
(users/where '(and (= status ?) (> age ?)) '("active" 18))

;; With limit and order
(users/where '(= status ?) '("active") limit: 10 order: '(desc created-at))

;; Comparison operators: =, <>, <, >, <=, >=
(users/where '(>= age ?) '(21))

;; LIKE queries
(users/where '(like name ?) '("%alice%"))

;; NULL checks
(users/where '(is deleted-at ?) '(null))
```

### Count Rows

```scheme
;; Count all
(users/count)  ; => 42

;; Count with condition
(users/count '(= status ?) '("active"))  ; => 15
```

## Creating and Updating

### Create a New Row

```scheme
(users/create '((name . "Charlie") (email . "charlie@example.com")))
; => ((id . 3) (name . "Charlie") (email . "charlie@example.com") ...)
```

The `create` function returns the newly created row (fetched by rowid).

### Save (Update) an Existing Row

```scheme
(let ((user (users/find '(= id ?) '(1))))
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

### Update by ID

```scheme
;; Convenience wrapper: find by ID, apply updates, save
(users/update 1 '((name . "Alicia") (status . "inactive")))
; => ((id . 1) (name . "Alicia") (status . "inactive") ...)

;; Returns #f if ID not found
(users/update 999 '((name . "Nobody")))  ; => #f
```

## Deleting

```scheme
(let ((user (users/find '(= id ?) '(1))))
  (users/delete user))  ; => #t
```

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
| `users/posts` | Get all posts for a user |
| `posts/users` | Get the user for a post |
| `users/add-posts` | Associate a post with a user |

```scheme
;; Get all posts for a user
(let ((user (users/find '(= id ?) '(1))))
  (users/posts user))  ; => #(((id . 1) (title . "Post 1") ...) ...)

;; Get the user for a post
(let ((post (posts/find '(= id ?) '(1))))
  (posts/users post))  ; => ((id . 1) (name . "Alice") ...)

;; With additional conditions
(let ((user (users/find '(= id ?) '(1))))
  (users/posts user '(= published ?) '(#t)))
```

## Helper Functions

### row-ref/default

Get a value from a row, treating SQL NULL as a default:

```scheme
(let ((user (users/find '(= id ?) '(1))))
  (row-ref/default 'name user)           ; => "Alice"
  (row-ref/default 'nickname user "N/A") ; => "N/A" if NULL
  (row-ref/default 'missing user))       ; => error: key doesn't exist
```

### row-metadata / row-metadata-set!

For tables with a `metadata` TEXT column storing s-expressions:

```scheme
;; Read metadata (returns alist, or default if NULL/invalid)
(let ((user (users/find '(= id ?) '(1))))
  (row-metadata user))  ; => ((theme . "dark") (language . "en"))

;; Set metadata (returns updated row alist)
(let ((user (users/find '(= id ?) '(1))))
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

The `orm-test` module (bundled in the `orm` egg) provides a mock database backend for testing code that uses `orm-db` without requiring a real database connection. It's installed automatically with `orm` — no separate install needed.

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
  (users/all)  ; => #(((id . 1) (name . "Alice")))

  ;; Inspect what SQL was executed
  (spy 'queries)  ; => (("SELECT ..." ()))
  )
```

### Spy Messages

| Message | Arguments | Description |
|---------|-----------|-------------|
| `queries` | none | Returns list of `(sql params)` pairs from all queries |
| `executions` | none | Returns list of `(sql params out-key)` from all executions |
| `on-query` | responses-or-proc | Set query responses: a list (consumed in order, last repeats) or a `(lambda (sql params) ...)` |
| `on-execute` | responses-or-proc | Set execute responses: a list or a `(lambda (sql params out-key) ...)` |
| `reset!` | none | Clear recorded queries and executions |

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
