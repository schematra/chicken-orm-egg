;; orm-db.scm - Abstract database interface
;; Provides a backend-agnostic interface for database operations.
;; Backends (like orm-db-sqlite or orm-db-rqlite) register themselves and
;; implement connect, close, query, and execute operations (and optionally batch).

(module orm-db

(
 db/backend
 db/connection
 db/path
 db/connect
 db/close
 db/query
 db/execute
 db/batch
 )

(import
 scheme
 chicken.base)

;; Current backend - an alist with procedures:
;;   connect: (path) -> connection
;;   close: (connection) -> void
;;   query: (connection ssql-or-string params) -> vector of alists
;;   execute: (connection ssql-or-string params out-key) -> value
;;   batch (optional): (connection statements) -> list of row vectors, where
;;     statements is a list of (ssql-or-string . params). Reads only.
(define db/backend (make-parameter #f))

;; Current database connection (opaque, backend-specific)
(define db/connection (make-parameter #f))

;; Database path/connection string
(define db/path (make-parameter #f))

;; Connect to database using current backend and path
(define (db/connect)
  (let ((backend (db/backend))
        (path (db/path)))
    (unless backend
      (error "No database backend configured. Set (db/backend) first."))
    (unless path
      (error "No database path configured. Set (db/path) first."))
    (let ((connect-proc (alist-ref 'connect backend)))
      (unless connect-proc
        (error "Backend does not implement 'connect'"))
      (db/connection (connect-proc path)))))

;; Close database connection
(define (db/close)
  (let ((backend (db/backend))
        (conn (db/connection)))
    (when (and backend conn)
      (let ((close-proc (alist-ref 'close backend)))
        (when close-proc
          (close-proc conn))
        (db/connection #f)))))

;; Execute a query (SELECT), returns vector of alists
(define (db/query ssql-form-or-string #!optional (params '()))
  (let ((backend (db/backend))
        (conn (db/connection)))
    (unless backend
      (error "No database backend configured"))
    (unless conn
      (error "No database connection. Call (db/connect) first."))
    (let ((query-proc (alist-ref 'query backend)))
      (unless query-proc
        (error "Backend does not implement 'query'"))
      (query-proc conn ssql-form-or-string params))))

;; Execute a statement (INSERT/UPDATE/DELETE), returns extracted value
(define (db/execute ssql-form-or-string #!optional (params '()) (out-key 'rows_affected))
  (let ((backend (db/backend))
        (conn (db/connection)))
    (unless backend
      (error "No database backend configured"))
    (unless conn
      (error "No database connection. Call (db/connect) first."))
    (let ((execute-proc (alist-ref 'execute backend)))
      (unless execute-proc
        (error "Backend does not implement 'execute'"))
      (execute-proc conn ssql-form-or-string params out-key))))

;; Run several read statements, returns a list of row vectors in order.
;; statements is a list of (ssql-or-string . params). Backends with a native
;; 'batch' (rqlite) send them in one request; others run them one by one.
(define (db/batch statements)
  (let ((backend (db/backend))
        (conn (db/connection)))
    (unless backend
      (error "No database backend configured"))
    (unless conn
      (error "No database connection. Call (db/connect) first."))
    (let ((batch-proc (alist-ref 'batch backend))
          (query-proc (alist-ref 'query backend)))
      (cond
       ((null? statements) '())
       (batch-proc (batch-proc conn statements))
       (query-proc (map (lambda (s) (query-proc conn (car s) (cdr s))) statements))
       (else (error "Backend does not implement 'query'"))))))

)
