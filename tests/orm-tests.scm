(import orm orm-db orm-db-sqlite orm-test)

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

(test-group "model hooks (unit)"
  (test-assert "make-model-hooks makes a model-hooks record"
    (model-hooks? (make-model-hooks)))
  (test-assert "model-hooks? rejects other values"
    (not (model-hooks? '())))

  (test "ref on an unregistered event is empty"
    '() (model-hooks-ref (make-model-hooks) 'before-create))

  (test-error "add! rejects an unknown event"
    (model-hooks-add! (make-model-hooks) 'before-frobnicate (lambda (row) row)))
  (test-error "add! rejects a non-procedure"
    (model-hooks-add! (make-model-hooks) 'before-create 'not-a-procedure))

  (test "hooks run in registration order"
    '(1 2 3)
    (let ((hooks (make-model-hooks))
          (calls '()))
      (for-each (lambda (n)
                  (model-hooks-add! hooks 'after-create
                                    (lambda (row) (set! calls (cons n calls)))))
                '(1 2 3))
      (run-after-hooks hooks 'after-create '())
      (reverse calls)))

  (test "before-hooks chain left to right"
    "a-1-2"
    (let ((hooks (make-model-hooks)))
      (model-hooks-add! hooks 'before-create
                        (lambda (row) (alist-update 'v (string-append (alist-ref 'v row) "-1") row)))
      (model-hooks-add! hooks 'before-create
                        (lambda (row) (alist-update 'v (string-append (alist-ref 'v row) "-2") row)))
      (alist-ref 'v (run-before-hooks hooks 'before-create '((v . "a"))))))

  (test-error "before-hooks reject a non-list return"
    (let ((hooks (make-model-hooks)))
      (model-hooks-add! hooks 'before-create (lambda (row) 'nope))
      (run-before-hooks hooks 'before-create '())))

  (test "run-before-hooks with #f hooks is identity"
    '((a . 1)) (run-before-hooks #f 'before-create '((a . 1))))
  (test-assert "run-after-hooks with #f hooks is a no-op"
    (run-after-hooks #f 'after-create '((a . 1))))

  (test "after-hooks ignore return values but all run"
    2
    (let ((hooks (make-model-hooks))
          (count 0))
      (model-hooks-add! hooks 'after-save (lambda (row) (set! count (+ count 1)) 'garbage))
      (model-hooks-add! hooks 'after-save (lambda (row) (set! count (+ count 1)) #f))
      (run-after-hooks hooks 'after-save '())
      count))

  (test "clear! with an event clears only that event"
    '(0 1)
    (let ((hooks (make-model-hooks))
          (noop (lambda (row) row)))
      (model-hooks-add! hooks 'before-create noop)
      (model-hooks-add! hooks 'before-save noop)
      (model-hooks-clear! hooks 'before-create)
      (list (length (model-hooks-ref hooks 'before-create))
            (length (model-hooks-ref hooks 'before-save)))))

  (test "clear! without an event clears everything"
    '(0 0)
    (let ((hooks (make-model-hooks))
          (noop (lambda (row) row)))
      (model-hooks-add! hooks 'before-create noop)
      (model-hooks-add! hooks 'before-save noop)
      (model-hooks-clear! hooks)
      (list (length (model-hooks-ref hooks 'before-create))
            (length (model-hooks-ref hooks 'before-save)))))

  (test "model-hook-event? accepts every advertised event"
    #f (memq #f (map model-hook-event? (model-hook-events))))
  (test "model-hook-events lists exactly the supported events"
    '(before-create after-create before-save after-save before-delete after-delete)
    (model-hook-events))
  (test-assert "model-hook-event? rejects anything else"
    (not (model-hook-event? 'before-update))))

;; --- Query descriptors (mock backend, no real DB) ---

;; A hand-built model: descriptors only need a table, a columns thunk and a
;; scope, so these tests don't go through define-model's PRAGMA introspection.
(define widget-columns-calls 0)
(define (widget-columns)
  (set! widget-columns-calls (+ widget-columns-calls 1))
  '((id integer (primary-key)) (name text) (created-at datetime) (owner-id integer)))

(define widget-owner (make-parameter #f))
(define widget-scope
  (make-model-scope
   (lambda ()
     (unless (widget-owner)
       (error "widget owner required"))
     (values '(= owner-id ?) (list (widget-owner))))))

(define (widgets/q) (make-model-query 'widgets widget-columns #f))
(define (owned-widgets/q) (make-model-query 'widgets widget-columns widget-scope))

(define widget-select '(select (columns id name created_at owner_id) (from widgets)))

;; Runs thunk with a fresh mock backend connected; thunk gets the spy.
(define (with-mock thunk)
  (let-values (((backend spy) (make-mock-backend)))
    (parameterize ((db/backend backend) (db/connection 'mock-connection))
      (thunk spy))))

;; The (ssql params) the mock saw for running q.
(define (rendered q)
  (with-mock
   (lambda (spy)
     (q/run q)
     (car (spy 'queries)))))

(test-group "query descriptors"
  (test-assert "users/q style constructor makes a descriptor"
    (model-query? (widgets/q)))
  (test-assert "model-query? rejects other values"
    (not (model-query? '())))

  (test "building touches neither the DB nor the model's columns"
    0
    (begin
      (set! widget-columns-calls 0)
      (parameterize ((db/backend #f) (db/connection #f))
        (q/then (q/count (q/offset (q/limit (q/order (q/where (owned-widgets/q) '(= name ?) "a")
                                                     'name)
                                            5)
                                   10))
                add1))
      widget-columns-calls))

  (test "a bare descriptor selects every column"
    (list widget-select '())
    (rendered (widgets/q)))

  (test "builders return new descriptors and leave the original alone"
    (list widget-select '())
    (let ((base (widgets/q)))
      (q/limit (q/where base '(= name ?) "a") 3)
      (rendered base)))

  (test "several q/where calls AND together, values in call order"
    (list (append widget-select '((where (and (= name ?) (> id ?) (= owner_id ?)))))
          '("a" 3 7))
    (rendered (q/where (q/where (q/where (widgets/q) '(= name ?) "a") '(> id ?) 3)
                       '(= owner-id ?) 7)))

  (test "q/where with several values"
    (list (append widget-select '((where (between id ? ?)))) '(1 9))
    (rendered (q/where (widgets/q) '(between id ? ?) 1 9)))

  (test "order converts kebab-case fields"
    (list (append widget-select '((order (desc created_at)))) '())
    (rendered (q/order (widgets/q) '(desc created-at))))

  (test "order accepts a bare field"
    (list (append widget-select '((order created_at))) '())
    (rendered (q/order (widgets/q) 'created-at)))

  (test "limit and offset"
    (list (append widget-select '((limit 10) (offset 20))) '())
    (rendered (q/offset (q/limit (widgets/q) 10) 20)))

  (test "q/by-id is a first by id"
    (list (append widget-select '((where (= id ?)) (limit 1))) '(42))
    (rendered (q/by-id (widgets/q) 42)))

  (test "q/count ignores order, limit and offset"
    (list '(select (columns (as (count *) _count)) (from widgets) (where (= name ?))) '("a"))
    (rendered (q/count (q/offset (q/limit (q/order (q/where (widgets/q) '(= name ?) "a") 'id) 5) 2))))

  (test "rows come back with kebab-case keys"
    '#(((owner-id . 1) (created-at . "x")))
    (with-mock
     (lambda (spy)
       (spy 'on-query (lambda (sql params) (vector '((owner_id . 1) (created_at . "x")))))
       (q/run (widgets/q)))))

  (test "q/first returns the first row"
    '((owner-id . 1))
    (with-mock
     (lambda (spy)
       (spy 'on-query (lambda (sql params) (vector '((owner_id . 1)))))
       (q/run (q/first (widgets/q))))))

  (test "q/first returns #f when nothing matches"
    #f
    (with-mock (lambda (spy) (q/run (q/first (widgets/q))))))

  (test "q/count returns the count"
    7
    (with-mock
     (lambda (spy)
       (spy 'on-query (lambda (sql params) (vector '((_count . 7)))))
       (q/run (q/count (widgets/q))))))

  (test "q/count returns 0 on an empty result"
    0
    (with-mock (lambda (spy) (q/run (q/count (widgets/q))))))

  (test "q/then composes in order"
    30
    (with-mock
     (lambda (spy)
       (spy 'on-query (lambda (sql params) (vector '((_count . 2)))))
       (q/run (q/then (q/then (q/count (widgets/q)) add1)
                      (lambda (n) (* n 10)))))))

  (test-error "q/then rejects a non-procedure"
    (q/then (widgets/q) 'nope))

  (test "the scope is applied at run time, ANDed first"
    (list (append widget-select '((where (and (= owner_id ?) (= name ?))))) '(5 "a"))
    (let ((q (q/where (owned-widgets/q) '(= name ?) "a")))
      (parameterize ((widget-owner 5))
        (rendered q))))

  (test-error "running a scoped descriptor without context fails closed"
    (rendered (owned-widgets/q)))

  (test "q/run-all returns one value per descriptor, in order"
    '(3 ((name . "w")) 2)
    (with-mock
     (lambda (spy)
       (spy 'on-query (list (vector '((_count . 3)))
                            (vector '((name . "w")))
                            (vector '((id . 1)) '((id . 2)))))
       (receive (n first rows)
           (q/run-all (q/count (widgets/q))
                      (q/first (widgets/q))
                      (widgets/q))
         (list n first (vector-length rows))))))

  (test "q/run-list returns a list"
    '(0 #f)
    (with-mock
     (lambda (spy)
       (q/run-list (list (q/count (widgets/q)) (q/first (widgets/q)))))))

  (test "q/run-list of no descriptors is empty"
    '()
    (with-mock (lambda (spy) (q/run-list '())))))

(test-group "batching"
  (test "q/run-all of 3 descriptors sends 1 batch with 3 statements"
    '(1 3 3)
    (with-mock
     (lambda (spy)
       (q/run-all (widgets/q) (q/count (widgets/q)) (q/by-id (widgets/q) 1))
       (list (length (spy 'batches))
             (length (car (spy 'batches)))
             (length (spy 'queries))))))

  (test "batched statements carry their own params"
    '((select (columns (as (count *) _count)) (from widgets) (where (= name ?))) "a")
    (with-mock
     (lambda (spy)
       (q/run-all (widgets/q) (q/count (q/where (widgets/q) '(= name ?) "a")))
       (cadr (car (spy 'batches))))))

  (test "q/run does not batch"
    '(0 1)
    (with-mock
     (lambda (spy)
       (q/run (widgets/q))
       (list (length (spy 'batches)) (length (spy 'queries))))))

  (test "a scope error in one descriptor sends nothing"
    '(error 0 0)
    (with-mock
     (lambda (spy)
       (let ((result (handle-exceptions exn 'error
                       (q/run-all (widgets/q) (owned-widgets/q)))))
         (list result (length (spy 'batches)) (length (spy 'queries))))))))

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

  ;; A generic mandatory model scope. "account" is intentionally used here to
  ;; keep the ORM feature independent from any tenant/agency convention.
  (db/execute "CREATE TABLE scoped_records (id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER NOT NULL, name TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)")

  (define current-account-id (make-parameter #f))
  (define account-scope
    (make-model-scope
     (lambda ()
       (let ((account-id (current-account-id)))
         (unless account-id
           (error "account scope required"))
         (values '(= account-id ?) (list account-id))))
     (lambda (row)
       (let ((account-id (current-account-id)))
         (unless account-id
           (error "account scope required"))
         (alist-update 'account-id account-id row)))))

  (define-model scoped-records scope: account-scope)

  ;; --- Lifecycle hook fixtures ---
  (db/execute "CREATE TABLE hooked_records (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, name TEXT, tag TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)")
  (define-model hooked-records)
  (model/has-many users hooked-records)

  (db/execute "CREATE TABLE hooked_scoped (id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER NOT NULL, name TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP)")
  (define-model hooked-scoped scope: account-scope)

  ;; Hooks are global mutable state on the model, so they leak between cases
  ;; unless every test brackets itself.
  (define (with-hooks thunk)
    (define (clear!)
      (model-hooks-clear! (hooked-records/hooks))
      (model-hooks-clear! (hooked-scoped/hooks)))
    (clear!)
    (let ((result (thunk)))
      (clear!)
      result))

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
          2 (q/run (q/count (users/q))))

        (test "count with condition"
          1 (q/run (q/count (q/where (users/q) '(= name ?) "Alice"))))

        (test "all returns vector of all rows"
          2 (vector-length (q/run (users/q))))

        (test "where filters correctly"
          1 (vector-length (q/run (q/where (users/q) '(= name ?) "Alice"))))

        (test "find returns single row"
          "Alice" (alist-ref 'name (q/run (q/first (q/where (users/q) '(= name ?) "Alice")))))

        (test "find returns #f when not found"
          #f (q/run (q/first (q/where (users/q) '(= name ?) "Nobody"))))

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
          1 (q/run (q/count (users/q)))))))

  (test-group "model scopes"
    (db/execute "DELETE FROM scoped_records")

    (test-error "missing scope context fails closed"
      (q/run (scoped-records/q)))

    (let* ((account-1-row
            (parameterize ((current-account-id 1))
              (scoped-records/create '((name . "Account 1")))))
           (account-2-row
            (parameterize ((current-account-id 2))
              (scoped-records/create
               '((account-id . 1) (name . "Account 2"))))))

      (test "create applies the scope write preparation"
        2 (alist-ref 'account-id account-2-row))

      (parameterize ((current-account-id 1))
        (test "all is scoped"
          '("Account 1")
          (map (lambda (row) (alist-ref 'name row))
               (vector->list (q/run (scoped-records/q)))))

        (test "where combines scope and caller conditions"
          1
          (vector-length
           (q/run (q/where (scoped-records/q) '(= name ?) "Account 1"))))

        (test "find cannot load another scope by primary key"
          #f
          (q/run (q/by-id (scoped-records/q) (alist-ref 'id account-2-row))))

        (test "count is scoped"
          1 (q/run (q/count (scoped-records/q))))

        (test "count combines scope and caller conditions"
          0 (q/run (q/count (q/where (scoped-records/q) '(= name ?) "Account 2"))))

        (test "save is atomically scoped"
          #f
          (scoped-records/save
           (alist-update
            'account-id 1
            (alist-update 'name "Cross-scope update" account-2-row))))

        (test "update cannot find another scoped row"
          #f
          (scoped-records/update
           (alist-ref 'id account-2-row)
           '((name . "Cross-scope update"))))

        (test-assert "delete preserves its historical return value"
          (scoped-records/delete account-2-row))

        (test "cross-scope writes leave the other row unchanged"
          "Account 2"
          (alist-ref
           'name
           (vector-ref
            (db/query "SELECT * FROM scoped_records WHERE id = ?"
                      (list (alist-ref 'id account-2-row)))
            0)))

        (test "save keeps an owned row inside its scope"
          1
          (alist-ref
           'account-id
           (scoped-records/save
            (alist-update
             'account-id 2
             (alist-update 'name "Updated" account-1-row)))))

        (test "delete removes an owned row"
          #t
          (scoped-records/delete
           (q/run (q/by-id (scoped-records/q) (alist-ref 'id account-1-row)))))

        (test "owned row is gone"
          0 (q/run (q/count (scoped-records/q))))))

    (test-error "a scope may not silently return no condition"
      (apply-model-scope-condition
       (make-model-scope (lambda () (values #f '())))
       #f
       '())))

  (test-group "model hooks (define-model)"
    (db/execute "DELETE FROM hooked_records")
    (db/execute "DELETE FROM hooked_scoped")

    (test "before-create transforms the inserted row"
      "tagged"
      (with-hooks
       (lambda ()
         (model/hook hooked-records (before-create row)
           (alist-update 'tag "tagged" row))
         (let ((created (hooked-records/create '((name . "a")))))
           ;; assert on what actually landed in the table, not the returned alist
           (alist-ref 'tag
                      (vector-ref (db/query "SELECT tag FROM hooked_records WHERE id = ?"
                                            (list (alist-ref 'id created)))
                                  0))))))

    (test "before-create hooks chain in registration order"
      "x-1-2"
      (with-hooks
       (lambda ()
         (model/hook hooked-records (before-create row)
           (alist-update 'tag (string-append (alist-ref 'tag row) "-1") row))
         (model/hook hooked-records (before-create row)
           (alist-update 'tag (string-append (alist-ref 'tag row) "-2") row))
         (alist-ref 'tag (hooked-records/create '((name . "b") (tag . "x")))))))

    (test "after-create receives the persisted row"
      #t
      (with-hooks
       (lambda ()
         (let ((seen #f))
           (model/hook hooked-records (after-create row)
             (set! seen (alist-ref 'id row)))
           (let ((created (hooked-records/create '((name . "c")))))
             (and seen (equal? seen (alist-ref 'id created))))))))

    ;; Pins the no-cascade decision: create fires ONLY create hooks.
    (test "create does not fire save hooks"
      0
      (with-hooks
       (lambda ()
         (let ((saves 0))
           (model/hook hooked-records ((before-save after-save) row)
             (set! saves (+ saves 1))
             row)
           (hooked-records/create '((name . "d")))
           saves))))

    (test "save hooks fire exactly once through update"
      '(1 1)
      (with-hooks
       (lambda ()
         (let ((before 0) (after 0)
               (row (hooked-records/create '((name . "e")))))
           (model/hook hooked-records (before-save r)
             (set! before (+ before 1))
             r)
           (model/hook hooked-records (after-save r)
             (set! after (+ after 1)))
           (hooked-records/update (alist-ref 'id row) '((name . "e2")))
           (list before after)))))

    (test "save hooks fire exactly once through add-hooked-records"
      '(1 1)
      (with-hooks
       (lambda ()
         (let ((before 0) (after 0)
               (parent (users/create '((name . "Parent"))))
               (child (hooked-records/create '((name . "f")))))
           (model/hook hooked-records (before-save r)
             (set! before (+ before 1))
             r)
           (model/hook hooked-records (after-save r)
             (set! after (+ after 1)))
           (users/add-hooked-records parent child)
           (list before after)))))

    ;; Wart #1 and #2 together: the before hook has already run (and its side
    ;; effect happened) when a scoped update matches nothing, but after is skipped.
    (test "before-save fires and after-save is skipped on a zero-row scoped update"
      '(#f 1 0)
      (with-hooks
       (lambda ()
         (let ((before 0) (after 0))
           (let ((row (parameterize ((current-account-id 2))
                        (hooked-scoped/create '((name . "owned by 2"))))))
             (model/hook hooked-scoped (before-save r)
               (set! before (+ before 1))
               r)
             (model/hook hooked-scoped (after-save r)
               (set! after (+ after 1)))
             (let ((result (parameterize ((current-account-id 1))
                             (hooked-scoped/save (alist-update 'name "nope" row)))))
               (list result before after)))))))

    (test "before-delete and after-delete fire, after-delete sees the pre-delete row"
      '("g" 0)
      (with-hooks
       (lambda ()
         (db/execute "DELETE FROM hooked_records")
         (let ((seen #f)
               (row (hooked-records/create '((name . "g")))))
           (model/hook hooked-records (before-delete r) r)
           (model/hook hooked-records (after-delete r)
             (set! seen (alist-ref 'name r)))
           (hooked-records/delete row)
           (list seen (q/run (q/count (hooked-records/q))))))))

    (test "an error in a before-hook aborts the operation"
      0
      (with-hooks
       (lambda ()
         (db/execute "DELETE FROM hooked_records")
         (model/hook hooked-records (before-create row)
           (error "nope"))
         (handle-exceptions exn #t
           (hooked-records/create '((name . "h"))))
         (q/run (q/count (hooked-records/q))))))

    ;; The ordering test: hooks run first, the scope writes last, so a hook can
    ;; never clobber a scope-injected column.
    (test "scope wins over a before-create hook"
      1
      (with-hooks
       (lambda ()
         (model/hook hooked-scoped (before-create row)
           (alist-update 'account-id 999 row))
         (parameterize ((current-account-id 1))
           (alist-ref 'account-id (hooked-scoped/create '((name . "scoped"))))))))

    (test "hooks are per-model"
      0
      (with-hooks
       (lambda ()
         (let ((count 0))
           (model/hook hooked-records (before-create row)
             (set! count (+ count 1))
             row)
           (users/create '((name . "Unrelated")))
           count))))

    (test "model/hook multi-event head shares one closure across events"
      2
      (with-hooks
       (lambda ()
         (let ((count 0))
           (model/hook hooked-records ((before-create before-save) row)
             (set! count (+ count 1))
             row)
           (let ((row (hooked-records/create '((name . "i")))))
             (hooked-records/save (alist-update 'name "i2" row)))
           count))))

    (test-error "registering an unknown event errors"
      (model-hooks-add! (hooked-records/hooks) 'before-update (lambda (row) row)))

    ;; Leave both models clean so the migrations group is unaffected.
    (model-hooks-clear! (hooked-records/hooks))
    (model-hooks-clear! (hooked-scoped/hooks)))

  (test-group "relationships (has-many)"
    (db/execute "DELETE FROM hooked_records")
    (let* ((parent (users/create '((name . "Rel Parent"))))
           (other (users/create '((name . "Rel Other")))))
      (users/add-hooked-records parent (hooked-records/create '((name . "r1") (tag . "a"))))
      (users/add-hooked-records parent (hooked-records/create '((name . "r2") (tag . "b"))))
      (users/add-hooked-records other (hooked-records/create '((name . "r3") (tag . "a"))))

      (test-assert "parent -> children is a descriptor"
        (model-query? (users/hooked-records/q parent)))

      (test "parent -> children runs to the parent's rows"
        '("r1" "r2")
        (map (lambda (row) (alist-ref 'name row))
             (vector->list (q/run (q/order (users/hooked-records/q parent) 'id)))))

      (test "parent -> children refines with q/"
        '("r2")
        (map (lambda (row) (alist-ref 'name row))
             (vector->list (q/run (q/where (users/hooked-records/q parent) '(= tag ?) "b")))))

      (test "child -> parent runs to the parent row"
        "Rel Parent"
        (alist-ref 'name
                   (q/run (hooked-records/users/q
                           (q/run (q/first (q/where (hooked-records/q) '(= name ?) "r1")))))))

      (test "child -> parent with a NULL foreign key runs to #f"
        #f
        (q/run (hooked-records/users/q
                (hooked-records/create '((name . "orphan")))))))
    (db/execute "DELETE FROM hooked_records"))

  (test-group "q/run-all (sqlite fallback)"
    (let ((total (vector-length (q/run (users/q)))))
      (receive (n bob rows)
          (q/run-all (q/count (users/q))
                     (q/first (q/where (users/q) '(= name ?) "Bob"))
                     (q/limit (users/q) 1))
        (test "count" total n)
        (test "first" "Bob" (alist-ref 'name bob))
        (test "rows" 1 (vector-length rows)))))

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
