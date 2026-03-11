;; orm-test.scm - Test helpers for the orm egg
;; Provides a mock backend and spy for testing code that uses orm-db
;; without requiring a real database connection.

(module orm-test (make-mock-backend)
  (import scheme chicken.base)

  (define (make-response-handler responses-or-proc)
    (if (procedure? responses-or-proc)
        responses-or-proc
        (let ((remaining responses-or-proc))
          (lambda args
            (let ((result (car remaining)))
              (when (pair? (cdr remaining))
                (set! remaining (cdr remaining)))
              result)))))

  (define (make-mock-backend)
    (let ((queries '())
          (executions '())
          (query-handler (lambda (sql params) (vector)))
          (execute-handler (lambda (sql params out-key) 0)))

      (define (spy msg . args)
        (case msg
          ((queries) queries)
          ((executions) executions)
          ((on-query) (set! query-handler (make-response-handler (car args))))
          ((on-execute) (set! execute-handler (make-response-handler (car args))))
          ((reset!) (set! queries '()) (set! executions '()))))

      (define backend
        `((connect . ,(lambda (path) 'mock-connection))
          (close   . ,(lambda (conn) #f))
          (query   . ,(lambda (conn sql params)
                        (set! queries (cons (list sql params) queries))
                        (query-handler sql params)))
          (execute . ,(lambda (conn sql params out-key)
                        (set! executions (cons (list sql params out-key) executions))
                        (execute-handler sql params out-key)))))

      (values backend spy))))
