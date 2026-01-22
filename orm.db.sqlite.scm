;; orm.db.sqlite.scm - SQLite3 backend for orm.db
;; Uses the sqlite3 egg for direct database access.

(module orm.db.sqlite

(
 sqlite3-backend
 )

(import
 scheme
 chicken.base
 (prefix sqlite3 sqlite3:)
 foops
 ssql
 logger)

;; Include the SSQL sqlite3 dialect translator
(include "ssql-sqlite3.scm")

(logger/install DB-SQLITE)
(logger/set-module-level! 'DB-SQLITE 'info)

;; Convert SSQL form or string to SQL string
(define (to-sql ssql-form-or-string)
  (if (string? ssql-form-or-string)
      ssql-form-or-string
      (ssql->sql 'sqlite3 ssql-form-or-string)))

;; Get column names from a prepared statement
(define (get-column-names stmt)
  (let ((count (sqlite3:column-count stmt)))
    (let loop ((i 0) (names '()))
      (if (>= i count)
          (reverse names)
          (loop (+ i 1) (cons (string->symbol (sqlite3:column-name stmt i)) names))))))

;; Convert a row (list of values) to an alist using column names
(define (row->alist column-names row-values)
  (map cons column-names row-values))

;; Get row data as a list of values
(define (get-row-values stmt column-count)
  (let loop ((i 0) (values '()))
    (if (>= i column-count)
        (reverse values)
        (loop (+ i 1) (cons (sqlite3:column-data stmt i) values)))))

;; Execute a query and return results as vector of alists
(define (sqlite3-query conn ssql-form-or-string params)
  (let* ((sql (to-sql ssql-form-or-string))
         (stmt (sqlite3:prepare conn sql)))
    (d "query: " sql " params: " params)
    ;; Use dynamic-wind to ensure finalization even on exceptions
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        ;; Bind parameters if any
        (unless (null? params)
          (apply sqlite3:bind-parameters! stmt params))
        ;; Get column names and count
        (let* ((col-count (sqlite3:column-count stmt))
               (column-names (get-column-names stmt)))
          ;; Collect all rows
          (let loop ((results '()))
            (if (sqlite3:step! stmt)
                ;; Row available - get column data
                (let ((row-values (get-row-values stmt col-count)))
                  (loop (cons (row->alist column-names row-values) results)))
                ;; No more rows
                (list->vector (reverse results))))))
      (lambda () (sqlite3:finalize! stmt)))))

;; Execute a statement and return the requested output value
(define (sqlite3-execute conn ssql-form-or-string params out-key)
  (let* ((sql (to-sql ssql-form-or-string))
         (stmt (sqlite3:prepare conn sql)))
    (d "execute: " sql " params: " params " out-key: " out-key)
    ;; Use dynamic-wind to ensure finalization even on exceptions
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        ;; Bind parameters if any
        (unless (null? params)
          (apply sqlite3:bind-parameters! stmt params))
        ;; Step through (for INSERT/UPDATE/DELETE this completes the operation)
        (sqlite3:step! stmt))
      (lambda () (sqlite3:finalize! stmt)))
    ;; Return requested value
    (case out-key
      ((last_insert_id) (sqlite3:last-insert-rowid conn))
      ((rows_affected) (sqlite3:change-count conn))
      (else (sqlite3:change-count conn)))))

;; Connect to a SQLite database
(define (sqlite3-connect path)
  (d "connecting to: " path)
  (sqlite3:open-database path))

;; Close a SQLite database connection
(define (sqlite3-close conn)
  (d "closing connection")
  (sqlite3:finalize! conn #t))

;; Backend definition - alist of procedures
(define (sqlite3-backend)
  `((connect . ,sqlite3-connect)
    (close   . ,sqlite3-close)
    (query   . ,sqlite3-query)
    (execute . ,sqlite3-execute)))

)
