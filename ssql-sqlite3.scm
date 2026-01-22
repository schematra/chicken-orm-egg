;; ssql-sqlite3.scm - SSQL dialect translator for SQLite3
;; Registers the 'sqlite3 symbol as the dialect identifier for SSQL translation.
(define *sqlite3-translator*
  (derive-object (*ansi-translator* self)
		 ;; Only override methods that differ from ANSI
		 ((clauses-order)
		  '(columns from table into set values where group having order limit offset union))))

(define-operators *sqlite3-translator*
  (limit prefix "LIMIT")
  (offset prefix "OFFSET")
  (is infix "IS")
  ;; Add any other SQLite-specific operators here
  )

(register-sql-engine!
 (lambda (obj) (and (symbol? obj) (eq? 'sqlite3 obj)))
  *sqlite3-translator*)
