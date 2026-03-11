(import orm-db orm-db-sqlite orm-test)

;; --- Parameter defaults ---

(test-group "orm-db parameters"
  ;; Reset state for a clean slate
  (db/backend #f)
  (db/connection #f)
  (db/path #f)

  (test "db/backend defaults to #f"
    #f (db/backend))
  (test "db/connection defaults to #f"
    #f (db/connection))
  (test "db/path defaults to #f"
    #f (db/path))

  (test "db/backend is settable"
    'dummy (begin (db/backend 'dummy) (db/backend)))
  (test "db/path is settable"
    "/tmp/test.db" (begin (db/path "/tmp/test.db") (db/path)))

  ;; Clean up
  (db/backend #f)
  (db/connection #f)
  (db/path #f))

;; --- Error handling when not configured ---

(test-group "orm-db error handling"
  (db/backend #f)
  (db/connection #f)
  (db/path #f)

  (test-error "db/connect errors without backend"
    (db/connect))

  (test-error "db/connect errors without path"
    (begin (db/backend '((connect . ,identity)))
           (db/path #f)
           (db/connect)))

  ;; Reset and test query/execute errors
  (db/backend #f)
  (db/connection #f)

  (test-error "db/query errors without backend"
    (db/query "SELECT 1"))

  (test-error "db/execute errors without backend"
    (db/execute "SELECT 1"))

  (begin
    (db/backend '((query . #f)))
    (db/connection #f))

  (test-error "db/query errors without connection"
    (db/query "SELECT 1"))

  (test-error "db/execute errors without connection"
    (db/execute "SELECT 1"))

  ;; Clean up
  (db/backend #f)
  (db/connection #f)
  (db/path #f))

;; --- Mock backend dispatch tests (using orm-test) ---

(test-group "orm-db mock backend dispatch"
  (let-values (((mock-backend spy) (make-mock-backend)))
    (spy 'on-query (lambda (sql params) (vector '((x . 1)))))
    (spy 'on-execute (lambda (sql params out-key) 1))

    (db/backend mock-backend)
    (db/path "/tmp/mock.db")

    (test-group "db/connect"
      (db/connect)
      (test "connect sets connection parameter"
        'mock-connection (db/connection)))

    (test-group "db/query"
      (let ((result (db/query "SELECT 1" '(42))))
        (test-assert "query returns a vector"
          (vector? result))
        (test "query result has one row"
          1 (vector-length result))
        (test "query logged with correct args"
          '("SELECT 1" (42))
          (car (spy 'queries)))))

    (test-group "db/execute"
      (let ((result (db/execute "INSERT INTO t VALUES (?)" '("val") 'last_insert_id)))
        (test "execute returns backend result"
          1 result)
        (test "execute logged with correct args"
          '("INSERT INTO t VALUES (?)" ("val") last_insert_id)
          (car (spy 'executions)))))

    (test-group "db/execute default out-key"
      (db/execute "DELETE FROM t")
      (test "execute defaults out-key to rows_affected"
        'rows_affected
        (caddr (car (spy 'executions)))))

    (test-group "db/close"
      (db/close)
      (test "close resets connection to #f"
        #f (db/connection)))

    (test-group "db/close is safe when already closed"
      (db/connection #f)
      (let ((exec-count (length (spy 'executions))))
        (db/close)
        (test "close is no-op when no connection"
          exec-count (length (spy 'executions)))))

    ;; Clean up
    (db/backend #f)
    (db/connection #f)
    (db/path #f)))

;; --- Integration with real SQLite backend ---

(test-group "orm-db sqlite integration"
  (db/backend (sqlite3-backend))
  (db/path ":memory:")
  (db/connect)

  (test-assert "connection is established"
    (db/connection))

  (db/execute "CREATE TABLE test_table (id INTEGER PRIMARY KEY, value TEXT)")

  (test "execute returns rows affected for insert"
    1 (db/execute "INSERT INTO test_table (value) VALUES (?)" '("hello") 'rows_affected))

  (let ((result (db/query "SELECT * FROM test_table")))
    (test-assert "query returns a vector"
      (vector? result))
    (test "query returns one row"
      1 (vector-length result))
    (test "query row has correct data"
      '((id . 1) (value . "hello"))
      (vector-ref result 0)))

  (let ((result (db/query "SELECT * FROM test_table WHERE value = ?" '("hello"))))
    (test "query with params returns correct row"
      "hello" (alist-ref 'value (vector-ref result 0))))

  (let ((result (db/query "SELECT * FROM test_table WHERE value = ?" '("nope"))))
    (test "query returns empty vector when no matches"
      0 (vector-length result)))

  (test "execute returns last insert id"
    2 (db/execute "INSERT INTO test_table (value) VALUES (?)" '("world") 'last_insert_id))

  (test "execute returns rows affected for delete"
    1 (db/execute "DELETE FROM test_table WHERE id = ?" '(1) 'rows_affected))

  (db/close)

  (test "connection is #f after close"
    #f (db/connection))

  ;; Clean up
  (db/backend #f)
  (db/path #f))
