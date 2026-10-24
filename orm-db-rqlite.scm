;; orm-db-rqlite.scm - rqlite backend for orm-db
;; Uses HTTP API to communicate with rqlite server.

(module orm-db-rqlite

(
 rqlite-backend
 )

(import
 scheme
 chicken.base
 http-client
 uri-common
 intarweb
 medea
 foops
 ssql
 logger)

;; Include the SSQL sqlite3 dialect translator (rqlite uses SQLite syntax)
(include "ssql-sqlite3.scm")
(include "ssql-rqlite.scm")

(logger/install DB-RQLITE)
(logger/set-module-level! 'DB-RQLITE 'info)

;; Convert SSQL form or string to SQL string
(define (to-sql ssql-form-or-string)
  (if (string? ssql-form-or-string)
      ssql-form-or-string
      (ssql->sql 'rqlite ssql-form-or-string)))

;; Build the /db/request payload: one #(sql param ...) entry per statement.
;; statements is a list of (sql . params) with sql already a string.
(define (rqlite-payload statements)
  (json->string
   (list->vector
    (map (lambda (s) (list->vector (cons (car s) (cdr s))))
         statements))))

;; Make HTTP request to rqlite server. All statements go in a single POST;
;; there is no transaction flag, so each one runs on its own.
(define (rqlite-request conn statements)
  (let* ((host         (alist-ref 'host conn))
         (json-payload (rqlite-payload statements))
         (uri          (uri-reference (string-append host "/db/request?timings&associative")))
         (request      (make-request uri: uri
                                     method: 'POST
                                     headers: (headers '((content-type application/json))))))
    (d "request: " (length statements) " statement(s)")
    (for-each (lambda (s) (d "  " (car s) " params: " (cdr s))) statements)
    (let-values (((data _req _resp) (with-input-from-request request json-payload read-json)))
      data)))

;; Extract out-key from every result of an rqlite response, in statement
;; order. Any per-statement error raises for the whole request.
(define (process-response resp out-key)
  (let ((results (alist-ref 'results resp)))
    (d "response: " resp)
    (let loop ((i 0) (acc '()))
      (if (or (not (vector? results)) (>= i (vector-length results)))
          (reverse acc)
          (let* ((res (vector-ref results i))
                 (err (alist-ref 'error res)))
            (when err
              (e "rqlite error (statement " i "): " err)
              (error 'rqlite err))
            (loop (+ i 1) (cons (alist-ref out-key res) acc)))))))

;; Send one statement and return its out-key value (#f if absent)
(define (rqlite-single conn ssql-form-or-string params out-key)
  (let ((vals (process-response
               (rqlite-request conn (list (cons (to-sql ssql-form-or-string) params)))
               out-key)))
    (and (pair? vals) (car vals))))

;; Execute a query and return results as vector of alists
;; rqlite with ?associative returns rows as objects with column names as keys
(define (rqlite-query conn ssql-form-or-string params)
  ;; rows is already a vector of alists (or #f if empty/error)
  (or (rqlite-single conn ssql-form-or-string params 'rows) '#()))

;; Execute a statement and return the requested output value
(define (rqlite-execute conn ssql-form-or-string params out-key)
  (or (rqlite-single conn ssql-form-or-string params out-key) 0))

;; Run several read statements in one request, returns a list of row vectors
(define (rqlite-batch conn statements)
  (let ((rows (process-response
               (rqlite-request conn (map (lambda (s) (cons (to-sql (car s)) (cdr s)))
                                         statements))
               'rows)))
    (unless (= (length rows) (length statements))
      (error 'rqlite "batch result count does not match statement count"
             (length statements) (length rows)))
    (map (lambda (r) (or r '#())) rows)))

;; Connect to rqlite - returns connection alist with host config
(define (rqlite-connect path)
  (d "connecting to: " path)
  `((host . ,path)))

;; Close rqlite connection - no-op for HTTP-based connection
(define (rqlite-close conn)
  (d "closing connection (no-op for rqlite)")
  #t)

;; Backend definition - alist of procedures
(define (rqlite-backend)
  `((connect . ,rqlite-connect)
    (close   . ,rqlite-close)
    (query   . ,rqlite-query)
    (execute . ,rqlite-execute)
    (batch   . ,rqlite-batch)))

)
