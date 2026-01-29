;; ssql-rqlite.scm - SSQL dialect translator for rqlite
;; rqlite uses SQLite's SQL dialect, so we delegate to the sqlite3 translator.
(register-sql-engine!
 (lambda (obj) (and (symbol? obj) (eq? 'rqlite obj)))
 *sqlite3-translator*)
