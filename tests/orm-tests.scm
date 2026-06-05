(import orm orm-db orm-db-sqlite)

;; --- Pure utility function tests (no DB needed) ---

(test-group "symbol->db-column"
  (test "converts kebab-case to snake_case"
    'created_at (symbol->db-column 'created-at))
  (test "no-op on single word"
    'name (symbol->db-column 'name))
  (test "multiple hyphens"
    'my_long_column (symbol->db-column 'my-long-column)))

(test-group "db-column->symbol"
  (test "converts snake_case symbol to kebab-case"
    'created-at (db-column->symbol 'created_at))
  (test "converts snake_case string to kebab-case"
    'created-at (db-column->symbol "created_at"))
  (test "no-op on single word symbol"
    'name (db-column->symbol 'name))
  (test "no-op on single word string"
    'name (db-column->symbol "name")))

(test-group "convert-result-keys"
  (test "converts all keys in alist"
    '((created-at . "2024-01-01") (user-name . "alice"))
    (convert-result-keys '((created_at . "2024-01-01") (user_name . "alice"))))
  (test "empty alist"
    '() (convert-result-keys '())))

(test-group "convert-results-vector"
  (test "converts all alists in vector"
    '#(((first-name . "alice")) ((first-name . "bob")))
    (convert-results-vector '#(((first_name . "alice")) ((first_name . "bob")))))
  (test "returns non-vector as-is"
    '() (convert-results-vector '())))

(test-group "get-primary-key-columns"
  (test "finds primary key column"
    '((id integer (primary-key #t)))
    (get-primary-key-columns
     '((id integer (primary-key #t))
       (name text)
       (email text (not-null #t)))))
  (test "returns empty for no primary key"
    '()
    (get-primary-key-columns
     '((name text) (email text)))))

(test-group "row-ref/default"
  (test "returns value when present"
    42 (row-ref/default 'age '((name . "alice") (age . 42))))
  (test "returns default for SQL NULL"
    #f (row-ref/default 'age '((name . "alice") (age . null))))
  (test "returns custom default for SQL NULL"
    0 (row-ref/default 'age '((name . "alice") (age . null)) 0))
  (test-error "errors on missing key"
    (row-ref/default 'missing '((name . "alice")))))

(test-group "row-metadata"
  (test "parses metadata string"
    '((key . "value"))
    (row-metadata '((metadata . "((key . \"value\"))"))))
  (test "returns default for null metadata"
    '() (row-metadata '((metadata . null))))
  (test "returns default when metadata key missing"
    '() (row-metadata '((name . "test"))))
  (test "returns custom default for missing metadata"
    '((fallback . #t))
    (row-metadata '((name . "test")) '((fallback . #t)))))

(test-group "row-metadata-set!"
  (test "sets metadata on row"
    "((key . \"value\"))"
    (alist-ref 'metadata
               (row-metadata-set! '((name . "test")) '((key . "value"))))))

(test-group "column-spec->sql"
  (test "plain column"
    "name TEXT" (column-spec->sql '(name text)))
  (test "primary key + autoincrement"
    "id INTEGER PRIMARY KEY AUTOINCREMENT"
    (column-spec->sql '(id integer (primary-key #t) (autoincrement #t))))
  (test "not-null"
    "title TEXT NOT NULL" (column-spec->sql '(title text (not-null #t))))
  (test "unique"
    "email TEXT UNIQUE" (column-spec->sql '(email text (unique #t))))
  (test "string default is quoted"
    "status TEXT DEFAULT 'active'"
    (column-spec->sql '(status text (default "active"))))
  (test "boolean default becomes TRUE/FALSE"
    "enabled BOOLEAN DEFAULT FALSE"
    (column-spec->sql '(enabled boolean (default #f))))
  (test "numeric default emitted as-is"
    "count INTEGER DEFAULT 0"
    (column-spec->sql '(count integer (default 0))))
  (test "not-null with default"
    "status TEXT NOT NULL DEFAULT 'active'"
    (column-spec->sql '(status text (not-null #t) (default "active"))))
  (test "foreign key references"
    "user_id INTEGER REFERENCES users(id)"
    (column-spec->sql '(user_id integer (foreign-key users id))))
  ;; ALTER TABLE ADD COLUMN restrictions (alter? = #t)
  (test "alter mode emits supported constraints"
    "status TEXT NOT NULL DEFAULT 'active'"
    (column-spec->sql '(status text (not-null #t) (default "active")) #t))
  (test-error "alter mode rejects primary-key"
    (column-spec->sql '(id integer (primary-key #t)) #t))
  (test-error "alter mode rejects unique"
    (column-spec->sql '(email text (unique #t)) #t))
  (test-error "alter mode rejects autoincrement"
    (column-spec->sql '(id integer (autoincrement #t)) #t)))

;; --- Integration tests (require SQLite) ---

(test-group "orm integration (sqlite)"
  ;; Set up in-memory SQLite database
  (db/backend (sqlite3-backend))
  (db/path ":memory:")
  (db/connect)

  ;; Create a test table
  (db/execute "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)")

  ;; Define a model for the test table
  (define-model users)

  (test-group "define-model generated functions"
    (test-group "columns and metadata"
      (test-assert "users/columns returns a list"
        (list? (users/columns)))
      (test "users/columns has correct column names"
        '(id name email created-at updated-at)
        (map car (users/columns)))
      (test "users/pkey returns primary key"
        '(id) (users/pkey)))

    (test-group "CRUD operations"
      (let ((alice (users/create '((name . "Alice") (email . "alice@example.com")))))
        (test-assert "create returns an alist"
          (list? alice))
        (test "created row has correct name"
          "Alice" (alist-ref 'name alice))
        (test "created row has correct email"
          "alice@example.com" (alist-ref 'email alice))
        (test-assert "created row has an id"
          (number? (alist-ref 'id alice)))

        ;; Create another user
        (users/create '((name . "Bob") (email . "bob@example.com")))

        (test "count returns correct number"
          2 (users/count))

        (test "count with condition"
          1 (users/count '(= name ?) '("Alice")))

        (test "all returns vector of all rows"
          2 (vector-length (users/all)))

        (test "where filters correctly"
          1 (vector-length (users/where '(= name ?) '("Alice"))))

        (test "find returns single row"
          "Alice" (alist-ref 'name (users/find '(= name ?) '("Alice"))))

        (test "find returns #f when not found"
          #f (users/find '(= name ?) '("Nobody")))

        ;; Save (update)
        (let ((updated (users/save (alist-update 'name "Alice Updated" alice))))
          (test "save updates the row"
            "Alice Updated" (alist-ref 'name updated)))

        ;; Update (by id)
        (let ((updated (users/update (alist-ref 'id alice) '((name . "Alice Final")))))
          (test "update changes the row"
            "Alice Final" (alist-ref 'name updated)))

        ;; Delete
        (test-assert "delete returns #t"
          (users/delete alice))
        (test "count after delete"
          1 (users/count)))))

  ;; --- Migration tests ---
  (test-group "migrations"
    (model/migration "001-create-posts"
      (lambda ()
        (model/schema/create-table 'posts
          '(id integer (primary-key #t) (autoincrement #t))
          '(title text (not-null #t))
          '(body text)))
      (lambda ()
        (model/schema/drop-table 'posts)))

    (model/migrate)

    ;; Verify table was created by querying it
    (test-assert "migration created posts table"
      (vector? (db/query "SELECT * FROM posts")))

    ;; add-columns must honor options (default/not-null), not just type
    (db/execute "INSERT INTO posts (title, body) VALUES ('hello', 'world')")
    (model/schema/add-columns 'posts
      '(status text (not-null #t) (default "draft"))
      '(view_count integer (default 0)))

    (let ((row (vector-ref (db/query "SELECT status, view_count FROM posts") 0)))
      (test "add-columns applies string default to existing rows"
        "draft" (alist-ref 'status row))
      (test "add-columns applies numeric default to existing rows"
        0 (alist-ref 'view_count row)))

    (test-error "add-columns rejects primary-key on existing table"
      (model/schema/add-columns 'posts '(pk integer (primary-key #t))))

    (model/rollback-all!)

    ;; Verify table was dropped
    (test-error "posts table dropped after rollback"
      (db/query "SELECT * FROM posts")))

  (db/close))
