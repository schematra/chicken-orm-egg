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

;; Make HTTP request to rqlite server
(define (rqlite-request conn sql params)
  (let* ((host         (alist-ref 'host conn))
         (json-payload (json->string `#(#(,sql ,@params))))
         (uri          (uri-reference (string-append host "/db/request?timings&associative")))
         (request      (make-request uri: uri
                                     method: 'POST
                                     headers: (headers '((content-type application/json))))))
    (d "request: " sql " params: " params)
    (let-values (((data _req _resp) (with-input-from-request request json-payload read-json)))
      data)))

;; Process rqlite response, extracting the specified key from results
(define (process-response resp out-key)
  (let* ((results   (alist-ref 'results resp))
         (first-res (and (vector? results)
                         (> (vector-length results) 0)
                         (vector-ref results 0)))
         (err       (and first-res (alist-ref 'error first-res)))
         (out-val   (and first-res (alist-ref out-key first-res))))
    (d "response: " resp)
    (if err
        (begin
          (e "rqlite error: " err)
          (error 'rqlite err))
        out-val)))

;; Execute a query and return results as vector of alists
;; rqlite with ?associative returns rows as objects with column names as keys
(define (rqlite-query conn ssql-form-or-string params)
  (let* ((sql  (to-sql ssql-form-or-string))
         (resp (rqlite-request conn sql params))
         (rows (process-response resp 'rows)))
    ;; rows is already a vector of alists (or #f if empty/error)
    (or rows '#())))

;; Execute a statement and return the requested output value
(define (rqlite-execute conn ssql-form-or-string params out-key)
  (let* ((sql  (to-sql ssql-form-or-string))
         (resp (rqlite-request conn sql params))
         (val  (process-response resp out-key)))
    (or val 0)))

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
    (execute . ,rqlite-execute)))

)
