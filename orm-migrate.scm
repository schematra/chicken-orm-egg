;;; orm-migrate.scm - CLI migration runner for the orm egg.
;;;
;;; Loads a user-provided migrations file (a series of (model/migration ...)
;;; forms), wires up a database backend selected at runtime via -b, and runs
;;; the migrations. The backend egg (orm-db-sqlite / orm-db-rqlite) is imported
;;; dynamically so the orm egg keeps no static dependency on either backend.
;;;
;;; Usage:
;;;   orm-migrate -b <backend> -path <conn> -f <migrations.scm> [-m <name>]
;;;   orm-migrate -b <backend> -path <conn> -f <migrations.scm> --rollback

(import scheme
        chicken.base
        chicken.eval
        chicken.file
        chicken.format
        chicken.process-context
        chicken.condition
        chicken.string
        orm
        orm-db)

;; Backend name -> (module-symbol constructor-symbol). The constructor name is
;; not uniform with the module name (sqlite3-backend vs. orm-db-sqlite), so the
;; mapping is explicit. Both are resolved at runtime via eval/import.
(define *backends*
  '(("sqlite" orm-db-sqlite sqlite3-backend)
    ("rqlite" orm-db-rqlite rqlite-backend)))

(define (die msg)
  (fprintf (current-error-port) "orm-migrate: ~a~%" msg)
  (exit 1))

(define (usage)
  (print "Usage: orm-migrate -b <backend> -path <conn> -f <file> [-m <name>] [--rollback]")
  (print "")
  (print "  -b, --backend    backend to use: "
         (string-intersperse (map car *backends*) " | ") " (required)")
  (print "  -path, --path    database path / connection string (required)")
  (print "  -f, --file       migrations file defining (model/migration ...) forms (required)")
  (print "  -m, --migration  target migration name; migrate up/down to it (default: latest)")
  (print "      --rollback   roll back all migrations to a clean state")
  (print "  -h, --help       show this help"))

(define (parse-args args)
  (let loop ((args args) (opts '()))
    (if (null? args)
        opts
        (let* ((flag (car args))
               (val (lambda ()
                      (if (null? (cdr args))
                          (die (string-append "missing value for " flag))
                          (cadr args)))))
          (cond
            ((member flag '("-h" "--help"))
             (loop (cdr args) (cons '(help . #t) opts)))
            ((member flag '("--rollback"))
             (loop (cdr args) (cons '(rollback . #t) opts)))
            ((member flag '("-b" "--backend"))
             (loop (cddr args) (cons (cons 'backend (val)) opts)))
            ((member flag '("-path" "--path" "-p"))
             (loop (cddr args) (cons (cons 'path (val)) opts)))
            ((member flag '("-f" "--file"))
             (loop (cddr args) (cons (cons 'file (val)) opts)))
            ((member flag '("-m" "--migration"))
             (loop (cddr args) (cons (cons 'target (val)) opts)))
            (else
             (die (string-append "unknown argument: " flag))))))))

(define (run opts)
  (let ((backend  (alist-ref 'backend opts))
        (path     (alist-ref 'path opts))
        (file     (alist-ref 'file opts))
        (target   (alist-ref 'target opts))
        (rollback (alist-ref 'rollback opts)))
    (unless backend (die "missing required -b <backend>"))
    (unless path    (die "missing required -path <conn>"))
    (unless file    (die "missing required -f <migrations-file>"))
    (let ((spec (assoc backend *backends*)))
      (unless spec
        (die (string-append "unknown backend '" backend "' (known: "
                            (string-intersperse (map car *backends*) ", ") ")")))
      (unless (file-exists? file)
        (die (string-append "migrations file not found: " file)))
      (let ((env  (interaction-environment))
            (mod  (cadr spec))
            (ctor (caddr spec)))
        ;; Make orm / orm-db visible to the loaded migrations file, and pull in
        ;; the chosen backend so its constructor can be called.
        (eval '(import orm orm-db) env)
        (eval `(import ,mod) env)
        (db/backend ((eval ctor env)))
        (db/path path)
        ;; Loading the file registers migrations via model/migration.
        (load file)
        (db/connect)
        (condition-case
            (begin
              (cond
                (rollback (model/rollback-all!))
                (target   (model/migrate target))
                (else     (model/migrate)))
              (db/close)
              (print "orm-migrate: done"))
          (exn (exn)
               (db/close)
               (die (or ((condition-property-accessor 'exn 'message) exn)
                        "migration failed"))))))))

(let ((opts (parse-args (command-line-arguments))))
  (if (alist-ref 'help opts)
      (begin (usage) (exit 0))
      (run opts)))
