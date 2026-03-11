(import orm-test orm-db)

(test-group "make-mock-backend"

  (test-group "default handlers"
    (let-values (((backend spy) (make-mock-backend)))
      (parameterize ((db/backend backend) (db/path "mock"))
        (db/connect)
        (test "default query returns empty vector"
          '#() (db/query "SELECT 1"))
        (test "default execute returns 0"
          0 (db/execute "INSERT INTO t VALUES (1)"))
        (db/close))))

  (test-group "on-query with procedure"
    (let-values (((backend spy) (make-mock-backend)))
      (spy 'on-query (lambda (sql params)
                       (vector '((id . 1) (name . "Alice")))))
      (parameterize ((db/backend backend) (db/path "mock"))
        (db/connect)
        (let ((result (db/query "SELECT * FROM users")))
          (test "custom query handler returns expected result"
            1 (vector-length result))
          (test "custom query handler row data"
            "Alice" (alist-ref 'name (vector-ref result 0))))
        (db/close))))

  (test-group "on-query with sequential list"
    (let-values (((backend spy) (make-mock-backend)))
      (spy 'on-query (list (vector '((id . 1)))
                           (vector '((id . 2)))))
      (parameterize ((db/backend backend) (db/path "mock"))
        (db/connect)
        (test "first query returns first response"
          1 (alist-ref 'id (vector-ref (db/query "Q1") 0)))
        (test "second query returns second response"
          2 (alist-ref 'id (vector-ref (db/query "Q2") 0)))
        (test "third query repeats last response"
          2 (alist-ref 'id (vector-ref (db/query "Q3") 0)))
        (db/close))))

  (test-group "on-execute with procedure"
    (let-values (((backend spy) (make-mock-backend)))
      (spy 'on-execute (lambda (sql params out-key) 42))
      (parameterize ((db/backend backend) (db/path "mock"))
        (db/connect)
        (test "custom execute handler returns expected result"
          42 (db/execute "INSERT INTO t VALUES (?)"))
        (db/close))))

  (test-group "on-execute with sequential list"
    (let-values (((backend spy) (make-mock-backend)))
      (spy 'on-execute (list 1 2))
      (parameterize ((db/backend backend) (db/path "mock"))
        (db/connect)
        (test "first execute returns 1"
          1 (db/execute "E1"))
        (test "second execute returns 2"
          2 (db/execute "E2"))
        (test "third execute repeats last"
          2 (db/execute "E3"))
        (db/close))))

  (test-group "spy queries and executions logs"
    (let-values (((backend spy) (make-mock-backend)))
      (parameterize ((db/backend backend) (db/path "mock"))
        (db/connect)
        (db/query "SELECT 1" '(10))
        (db/query "SELECT 2" '(20))
        (db/execute "INSERT" '("a") 'last_insert_id)

        (test "queries log has 2 entries"
          2 (length (spy 'queries)))
        (test "most recent query is first"
          '("SELECT 2" (20)) (car (spy 'queries)))
        (test "older query is second"
          '("SELECT 1" (10)) (cadr (spy 'queries)))

        (test "executions log has 1 entry"
          1 (length (spy 'executions)))
        (test "execution log entry has correct args"
          '("INSERT" ("a") last_insert_id) (car (spy 'executions)))
        (db/close))))

  (test-group "spy reset!"
    (let-values (((backend spy) (make-mock-backend)))
      (parameterize ((db/backend backend) (db/path "mock"))
        (db/connect)
        (db/query "SELECT 1")
        (db/execute "INSERT")
        (spy 'reset!)
        (test "queries cleared after reset"
          '() (spy 'queries))
        (test "executions cleared after reset"
          '() (spy 'executions))
        (db/close)))))
