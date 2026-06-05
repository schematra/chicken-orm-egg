(module orm

(
 load-table-metadata
 register-model!
 get-model-metadata
 symbol->db-column
 db-column->symbol
 convert-result-keys
 convert-results-vector
 get-primary-key-columns
 build-pk-where
 map-field-names->columns
 define-model
 model/has-many
 model/migration
 model/migrate
 model/rollback-all!
 column-spec->sql
 model/schema/create-table
 model/schema/drop-table
 model/schema/add-columns
 model/schema/drop-columns
 row-ref/default
 row-metadata
 row-metadata-set!
 )

(import
 scheme
 chicken.base
 chicken.module
 chicken.syntax
 chicken.string
 chicken.port
 chicken.condition
 srfi-1
 srfi-13
 (only srfi-133 vector-map)
 orm-db
 logger
 sql-null
 )

;; Import chicken.base for make-list at expansion time as well
(import-for-syntax chicken.base)

;; Make conc available at expansion time
(import-for-syntax chicken.string)
(import-for-syntax srfi-13)

(logger/install ORM)
(logger/set-module-level! 'ORM 'info)

;; Global registry for model metadata
(define *model-registry* '())

;; Model metadata management
(define (register-model! name metadata)
  (set! *model-registry*
        (alist-update name metadata *model-registry*)))

(define (get-model-metadata name)
  (alist-ref name *model-registry*))

;; Table introspection
(define (load-table-metadata table-name-sym)
  (let* (;; Convert kebab-case to snake_case for actual table name
         (db-table-name (symbol->db-column table-name-sym))
         (pragma-query (conc "PRAGMA table_info(" db-table-name ")"))
         (columns-info (vector->list (db/query pragma-query))))
    (map (lambda (row)
           ;; row format: (cid name type notnull dflt_value pk)
           (let ((name (db-column->symbol (alist-ref 'name row)))
                 (type-str (alist-ref 'type row))
                 (not-null (= (alist-ref 'notnull row) 1))
                 (default (alist-ref 'dflt_value row))
                 (pk (= (alist-ref 'pk row) 1)))
             `(,name ,(string->symbol (string-downcase type-str))
                     ,@(if pk '((primary-key)) '())
                     ,@(if (and not-null (not pk)) '((not-null)) '())
                     ,@(if default `((default ,default)) '()))))
         columns-info)))

;; Helper to get primary key columns
(define (get-primary-key-columns columns)
  (filter (lambda (col-spec)
            (let ((options (cddr col-spec)))
              (and (pair? options)
                   (alist-ref 'primary-key options))))
          columns))

;; Helper to build WHERE clause for primary key
;; Returns (values condition values) where condition uses ? placeholders
(define (build-pk-where pk-columns row)
  (if (null? pk-columns)
      (error "No primary key found for row operations")
      (let* ((pk-data
              (map (lambda (col-spec)
                     (let* ((col-name (car col-spec))
                            (db-col-name (symbol->db-column col-name))
                            (value (alist-ref col-name row)))
                       (cons `(= ,db-col-name ?) value)))
                   pk-columns))
             (pk-conditions (map car pk-data))
             (pk-values (map cdr pk-data))
             (condition (if (= (length pk-conditions) 1)
                            (car pk-conditions)
                            `(and ,@pk-conditions))))
        (values condition pk-values))))

;; Convert scheme symbol to database column name (kebab-case to snake_case)
;; this is symbol -> symbol
(define (symbol->db-column sym)
  (string->symbol
   (string-map (lambda (c)
                 (if (eq? c #\-) #\_ c))
               (symbol->string sym))))

;; Convert database column name to scheme field name (snake_case to kebab-case)
;; this is (string | symbol) -> symbol
(define (db-column->symbol sym-or-string)
  (let ((col-name (if (symbol? sym-or-string) (symbol->string sym-or-string) sym-or-string)))
    (string->symbol
     (string-map (lambda (c)
                   (if (eq? c #\_) #\- c))
		 col-name))))

;; Convert all keys in an alist from snake_case to kebab-case
(define (convert-result-keys alist)
  (map (lambda (pair)
         (cons (db-column->symbol (car pair)) (cdr pair)))
       alist))

;; Convert all alists in a vector of results
(define (convert-results-vector vec)
  (if (vector? vec)
      (vector-map convert-result-keys vec)
      vec))

(define (map-field-names->columns list columns)
  (map (lambda (elt)
	 (cond
	  ((list? elt) (map-field-names->columns elt columns))
	  ((and (symbol? elt) (member elt columns)) (symbol->db-column elt))
	  (else elt)))
       list))

;; Helper function to get value from a row (alist) with default handling for SQL NULL
;; SQL NULL is represented as the symbol 'null, this function treats that as the default
;; If the key doesn't exist in the row, returns the default value (similar to alist-ref behavior)
(define (row-ref/default key row #!optional (default #f))
  (let ((pair (assoc key row)))
    (if pair
        ;; Key exists, check if value is SQL NULL
        (if (or (eq? (cdr pair) 'null)
                (sql-null? (cdr pair)))
            default
            (cdr pair))
        ;; Key doesn't exist, error out
        (error "Key does not exist in row: " key))))

;; Helper function to safely retrieve and parse metadata from a row
;; Metadata is stored as a string representation of a Scheme s-expression
;; Returns the parsed alist if valid, or default (empty list) if null/invalid/missing
(define (row-metadata row #!optional (default '()))
  (condition-case
   (let ((metadata-blob (alist-ref 'metadata row)))
     (if (or (not metadata-blob) (eq? metadata-blob 'null))
         default
         (with-input-from-string metadata-blob read)))
   [exn () default]))

(define (row-metadata-set! row metadata)
  (condition-case
      (let ((metadata-str (with-output-to-string (lambda () (write metadata)))))
        (alist-update 'metadata metadata-str row))
    [exn () #f]))

;; Main define-model macro
(define-syntax define-model
  (er-macro-transformer
   (lambda (x r c)
     (let* ((table-name (cadr x))
            (table-name-str (symbol->string table-name))
            ;; Generate function names
            (load-metadata-name (string->symbol (conc table-name-str "/load-metadata")))
            (columns-name (string->symbol (conc table-name-str "/columns")))
            (pkey-name (string->symbol (conc table-name-str "/pkey")))
            (where-name (string->symbol (conc table-name-str "/where")))
            (all-name (string->symbol (conc table-name-str "/all")))
            (find-name (string->symbol (conc table-name-str "/find")))
            (count-name (string->symbol (conc table-name-str "/count")))
            (create-name (string->symbol (conc table-name-str "/create")))
            (save-name (string->symbol (conc table-name-str "/save")))
            (update-name (string->symbol (conc table-name-str "/update")))
            (delete-name (string->symbol (conc table-name-str "/delete")))
	    ;; sanitized versions
	    (%let (r 'let))
	    (%let* (r 'let*))
	    (%define (r 'define))
	    (%map (r 'map))
	    (%car (r 'car))
	    (%if (r 'if)))

       `(,(r 'begin)
         ;; Export all generated functions (must be at module toplevel)
         (,(r 'export) ,load-metadata-name ,columns-name ,pkey-name
          ,where-name ,all-name ,find-name ,count-name ,create-name ,save-name ,update-name ,delete-name)

         ;; Load metadata function
         (,%define (,load-metadata-name)
                   (,%let ((metadata (load-table-metadata ',table-name)))
                          (register-model! ',table-name metadata)
                          metadata))

         ;; Get columns function
         (,%define (,columns-name)
                   (,(r 'or) (get-model-metadata ',table-name)
                    (,load-metadata-name)))

         ;; Get primary key function
         (,%define (,pkey-name)
                   (,%map ,%car (get-primary-key-columns (,columns-name))))

         ;; Where function - returns vector of alists
         (,%define (,where-name #!optional conditions (values '()) #!key (limit #f) (order #f) (offset #f))
                   (,%let* ((columns (,%map ,%car (,columns-name)))
                            (db-columns (,%map (,(r 'lambda) (col-spec)
                                                (symbol->db-column col-spec)) columns))
                            (db-table-name (symbol->db-column ',table-name))
                            ;; Convert order field from kebab-case to snake_case
                            ;; order can be: symbol | (asc symbol) | (desc symbol)
                            (converted-order
                             (,(r 'if) order
                                       (,(r 'if) (,(r 'list?) order)
                                                 ;; (asc/desc field-name) - convert cadr
                                                 (,(r 'list) (,(r 'car) order)
                                                             (,(r 'if) (,(r 'member) (,(r 'cadr) order) columns)
                                                                       (symbol->db-column (,(r 'cadr) order))
                                                                       (,(r 'cadr) order)))
                                                 ;; just field-name - convert it
                                                 (,(r 'if) (,(r 'member) order columns)
                                                           (symbol->db-column order)
                                                           order))
                                       #f))
                            (query-parts `(select (columns ,@db-columns)
                                            (from ,db-table-name)
                                            ,@(,(r 'if) conditions `((where ,(map-field-names->columns conditions columns))) '())
                                            ,@(,(r 'if) converted-order `((order ,converted-order)) '())
                                            ,@(,(r 'if) limit `((limit ,limit)) '())
                                            ,@(,(r 'if) offset `((offset ,offset)) '()))))
                           (convert-results-vector (db/query query-parts values))))

         ;; Convenience "all" search
         (,%define (,all-name #!key (limit #f) (order #f) (offset #f))
                   (,where-name #f '() limit: limit order: order offset: offset))

         ;; Find function - returns single alist or #f
         (,%define (,find-name #!optional conditions (values '()) #!key (order #f))
                   (,%let ((results (,where-name conditions values limit: 1 order: order)))
		          (,%if (,(r 'and) (,(r 'vector?) results) (,(r 'eq?) (,(r 'vector-length) results) 1))
		                (,(r 'vector-ref) results 0)
		                #f)))

         ;; Count function - returns integer count of matching rows
         (,%define (,count-name #!optional conditions (values '()))
                   (,%let* ((columns (,columns-name))
                            (db-columns (,%map (,(r 'lambda) (col-spec)
                                                (symbol->db-column col-spec)) (,%map ,%car columns)))
                            (db-table-name (symbol->db-column ',table-name))
                            (query-parts `(select (columns (as (count *) _count))
                                            (from ,db-table-name)
                                            ,@(,(r 'if) conditions `((where ,(map-field-names->columns conditions (,%map ,%car columns)))) '())))
                            (result (db/query query-parts values)))
                           ;; Safely extract count - handle empty result or errors
                           (,%if (,(r 'and) result (,(r 'vector?) result) (,(r 'eq?) (,(r 'vector-length) result) 1))
                                 (,(r 'alist-ref) '_count (,(r 'vector-ref) result 0))
                                 0)))

         ;; Create function - takes alist, returns alist of created row
         (,%define (,create-name row-alist)
		   (,%let* ((columns (,columns-name))
			    (db-columns (,%map (,(r 'lambda) (col-spec)
						(symbol->db-column (,%car col-spec))) columns))
			    (filtered-alist (,(r 'filter) (,(r 'lambda) (pair)
							   (,(r 'not) (,(r 'null?) (,(r 'cdr) pair)))) row-alist))
			    (insert-columns (,%map (,(r 'lambda) (pair) (symbol->db-column (,(r 'car) pair))) filtered-alist))
			    (values (,%map ,(r 'cdr) filtered-alist))
			    (placeholders (,(r 'make-list) (,(r 'length) values) '?))
			    (db-table-name (symbol->db-column ',table-name))
			    (query `(insert (into ,db-table-name)
					    (columns ,@insert-columns)
					    (values #(,@placeholders))))
			    (new_id (db/execute query values 'last_insert_id)))
			   ;; Return the created row by finding it with the new ID
			   (,find-name '(= rowid ?) (,(r 'list) new_id))))

         ;; Save function - takes alist, updates existing row
         (,%define (,save-name row-alist)
	           (,%let* ((columns (,columns-name))
		            (pk-columns (get-primary-key-columns columns)))
	                   (,(r 'let-values) (((pk-where pk-values)
			                       (build-pk-where pk-columns row-alist)))
	                    (,%let* ((non-pk-pairs (,(r 'filter) (,(r 'lambda) (pair)
						                  (,%let ((col-name (,(r 'car) pair)))
							                 (,(r 'and)
							                  ;; Not a primary key column
							                  (,(r 'not) (,(r 'any) (,(r 'lambda) (pk-col)
										                 (,(r 'eq?) col-name (,(r 'car) pk-col)))
								                      pk-columns))
							                  ;; Not a timestamp column (updated_at, created_at)
							                  (,(r 'not) (,(r 'memq) col-name '(updated-at created-at))))))
                                                    row-alist))
		                     (set-clauses (,%map (,(r 'lambda) (pair)
						          `(,(symbol->db-column (,(r 'car) pair)) ?))
					                 non-pk-pairs))
		                     (set-values (,%map ,(r 'cdr) non-pk-pairs))
		                     (all-values (,(r 'append) set-values pk-values))
		                     (db-table-name (symbol->db-column ',table-name))
		                     (query `(update ,db-table-name
				                     (set ,@set-clauses (updated_at CURRENT_TIMESTAMP))
				                     (where ,pk-where))))
		                    (db/execute query all-values)
                                    ;; return a fresh version, because some fields might update on save
                                    (,find-name '(= id ?) (list (alist-ref 'id row-alist)))))))

         ;; update function, wrapper around find -> save
         (,%define (,update-name id updates)
                   (,%let ((row (,find-name '(= id ?) (,(r 'list) id))))
                          (,%if row
                                (,save-name (,(r 'fold) (,(r 'lambda) (pair acc)
                                                          (,(r 'alist-update) (,(r 'car) pair) (,(r 'cdr) pair) acc))
                                             row
                                             updates))
                                #f)))

         ;; Delete function - takes alist, deletes the row
         (,%define (,delete-name row-alist)
		   (,(r 'let-values) (((pk-where pk-values)
				       (,%let* ((columns (,columns-name))
						(pk-columns (get-primary-key-columns columns)))
					       (build-pk-where pk-columns row-alist))))
		    (,%let* ((db-table-name (symbol->db-column ',table-name))
			     (query `(delete (from ,db-table-name) (where ,pk-where))))
			    (db/execute query pk-values)
			    #t)))
	 ;; load metadata
	 (,load-metadata-name))))))

;; Relationship support - has-many
(define-syntax model/has-many
  (er-macro-transformer
   (lambda (x r c)
     (let* ((parent-table (cadr x))
            (child-table (caddr x))
            (parent-str (symbol->string parent-table))
            (child-str (symbol->string child-table))
            ;; Convention: child table has parent_id foreign key (singular)
            ;; Convert "rooms" -> "room", "users" -> "user", etc.
            (parent-singular (if (string-suffix? "s" parent-str)
                                (string-drop-right parent-str 1)
                                parent-str))
            (fk-column (string->symbol (conc parent-singular "-id")))
            ;; Generate function names
            (parent-get-children-name (string->symbol (conc parent-str "/" child-str)))
            (child-get-parent-name (string->symbol (conc child-str "/" parent-str)))
            (parent-add-child-name (string->symbol (conc parent-str "/add-" child-str)))
            (parent-find-name (string->symbol (conc parent-str "/find")))
            (child-where-name (string->symbol (conc child-str "/where")))
            (child-find-name (string->symbol (conc child-str "/find")))
            (child-save-name (string->symbol (conc child-str "/save")))
	    (%let  (r 'let))
	    (%let* (r 'let*)))

       `(,(r 'begin)
         ;; Export relationship functions
         (,(r 'export) ,parent-get-children-name ,child-get-parent-name ,parent-add-child-name)

         ;; Parent -> Children (e.g., users/sessions) - returns list
         (,(r 'define) (,parent-get-children-name parent-row #!optional conditions (values '()) #!key (limit #f) (order #f) (offset #f))
          (,%let* ((fk-column ',fk-column)
		   (parent-pk (,(r 'alist-ref) 'id parent-row))
                   (base-condition `(= ,fk-column ?))
                   (base-values (,(r 'list) parent-pk))
                   (full-condition (,(r 'if) conditions
                                    `(and ,base-condition ,conditions)
                                    base-condition))
                   (full-values (,(r 'if) conditions
                                 (,(r 'append) base-values values)
                                 base-values)))
		  (,child-where-name full-condition full-values limit: limit order: order offset: offset)))

         ;; Child -> Parent (e.g., sessions/user) - returns single element or #f
         (,(r 'define) (,child-get-parent-name child-row)
          (,%let ((fk-value (,(r 'alist-ref) ',fk-column child-row)))
		 (,(r 'if) fk-value
                  (,parent-find-name `(= id ?) (,(r 'list) fk-value))
                  #f)))

         ;; Add relationship (e.g., users/add-session)
         (,(r 'define) (,parent-add-child-name parent-row child-row)
          (,%let* ((parent-pk (,(r 'alist-ref) 'id parent-row))
                   (updated-child (,(r 'alist-update) ',fk-column parent-pk child-row)))
		  (,child-save-name updated-child))))))))

;; Migration system
(define *migrations* '())

;; Register a migration - simple function instead of macro
(define (model/migration name up-proc down-proc)
  (set! *migrations*
        (alist-update name (cons up-proc down-proc) *migrations*)))

;; Get current migration version from database
(define (get-current-migration-version)
  (condition-case
   (db/execute "CREATE TABLE IF NOT EXISTS schema_migrations (
                    version TEXT PRIMARY KEY,
                    applied_at DATETIME DEFAULT CURRENT_TIMESTAMP
                  )")
   (var (exn)
        (w "Could not create schema_migrations table: "
           ((condition-property-accessor 'exn 'message) var))
        #f))
  ;; Get latest version
  (let* ((results (db/query "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1"))
	 (result (if (and (vector? results) (= (vector-length results) 1)) (vector-ref results 0) #f)))
    (if result (alist-ref 'version result) #f)))

;; Record migration application
(define (record-migration-version! version)
  (let ((rows-affected (db/execute "INSERT INTO schema_migrations (version) VALUES (?)" (list version))))
    (unless (= rows-affected 1)
      (error "[E:ORM] could not insert migration version"))))

;; Remove migration record
(define (remove-migration-version! version)
  (let ((rows-affected (db/execute "DELETE FROM schema_migrations WHERE version = ?" (list version))))
    (unless (= rows-affected 1)
      (error "[E:ORM] could not delete migration version"))))

;; Apply migration up
(define (apply-migration-up! name)
  (let ((migration (alist-ref name *migrations*)))
    (if migration
        (begin
          ((car migration))  ; call up procedure
          (record-migration-version! name)
          (i "Applied migration: " name))
        (error "Migration not found: " name))))

;; Apply migration down
(define (apply-migration-down! name)
  (let ((migration (alist-ref name *migrations*)))
    (if migration
        (begin
          ((cdr migration))  ; call down procedure
          (remove-migration-version! name)
          (i "Rolled back migration: " name))
        (error "Migration not found: " name))))

;; Roll back all migrations to clean state
(define (model/rollback-all!)
  (let* ((current-version (get-current-migration-version))
         (migration-names (map car *migrations*)))
    (if current-version
        (let ((current-idx (list-index (lambda (m) (equal? m current-version)) migration-names)))
          (if current-idx
              (begin
                ;; Apply all down migrations in reverse order from current back to first
                (for-each apply-migration-down!
                          (reverse (take migration-names (+ current-idx 1))))
                (i "Rolled back all migrations"))
              (w "Current migration not found in migration list")))
        (i "No migrations to roll back"))))

;; Main migrate function
(define (model/migrate #!optional target-version)
  (d "will try to migrate on database " (db/path))
  (let* ((current-version (get-current-migration-version))
         (migration-names (map car *migrations*))
         (target (or target-version
                     (if (null? migration-names) #f (car (reverse migration-names))))))

    (cond
     ((not target)
      (i "No migrations to apply"))
     ((not current-version)
      ;; Apply all migrations up to target
      (let ((target-idx (list-index (lambda (m) (equal? m target)) migration-names)))
        (if target-idx
            (for-each apply-migration-up!
                      (take migration-names (+ 1 target-idx)))
            (error "Target migration not found: " target))))
     ((string=? current-version target)
      (i "Already at target version: " target))
     (else
      ;; Determine direction and apply migrations
      (let* ((current-idx (list-index (lambda (m) (equal? m current-version)) migration-names))
             (target-idx (list-index (lambda (m) (equal? m target)) migration-names)))
        (cond
         ((not current-idx)
          (error "Current migration not found in migration list: " current-version))
         ((not target-idx)
          (error "Target migration not found: " target))
         ((> target-idx current-idx)
          ;; Apply migrations up
          (for-each apply-migration-up!
                    (drop (take migration-names (+ target-idx 1)) (+ current-idx 1))))
         ((< target-idx current-idx)
          ;; Apply migrations down
          (for-each apply-migration-down!
                    (reverse (drop (take migration-names (+ current-idx 1)) (+ target-idx 1)))))))))))

;; Schema manipulation helpers for migrations

;; Helper to convert column type symbol to SQL type string
(define (column-type->sql col-type)
  (case col-type
    ((integer) "INTEGER")
    ((string text) "TEXT")
    ((real float) "REAL")
    ((blob) "BLOB")
    ((datetime) "DATETIME")
    ((boolean) "BOOLEAN")
    (else (symbol->string col-type))))

;; Render a DEFAULT clause from a default value, or #f if none given.
;; options is the cddr of a column spec; (default <val>) appears as (default . (<val>)).
(define (column-default->sql options)
  (let ((default-list (alist-ref 'default options)))
    (if default-list
        (let ((default (car default-list)))
          (cond
           ;; Handle string literals - wrap in SQL single quotes
           ((string? default)
            (conc "DEFAULT '" default "'"))
           ;; Handle boolean values - convert to SQL TRUE/FALSE
           ((boolean? default)
            (conc "DEFAULT " (if default "TRUE" "FALSE")))
           ;; Everything else (symbols, numbers) as-is
           (else
            (conc "DEFAULT " default))))
        #f)))

;; Build the list of constraint SQL fragments for a column spec's options.
;; When alter? is true, reject the constraints SQLite forbids on ADD COLUMN
;; (PRIMARY KEY, UNIQUE, AUTOINCREMENT) rather than silently emitting invalid SQL.
;; See https://sqlite.org/lang_altertable.html for the full set of restrictions.
(define (column-options->constraints options #!optional alter?)
  (when alter?
    (cond
     ((alist-ref 'primary-key options)
      (error "ALTER TABLE ADD COLUMN cannot add a PRIMARY KEY column" options))
     ((alist-ref 'unique options)
      (error "ALTER TABLE ADD COLUMN cannot add a UNIQUE column" options))
     ((alist-ref 'autoincrement options)
      (error "ALTER TABLE ADD COLUMN cannot add an AUTOINCREMENT column" options))))
  (filter identity
          (list
           (if (alist-ref 'primary-key options) "PRIMARY KEY" #f)
           (if (alist-ref 'autoincrement options) "AUTOINCREMENT" #f)
           (if (alist-ref 'not-null options) "NOT NULL" #f)
           (if (alist-ref 'unique options) "UNIQUE" #f)
           (column-default->sql options)
           (let ((foreign-key-list (alist-ref 'foreign-key options)))
             (if foreign-key-list
                 (let ((fk-table (car foreign-key-list))
                       (fk-column (cadr foreign-key-list)))
                   (conc "REFERENCES " fk-table "(" fk-column ")"))
                 #f)))))

;; Render a single column spec (name type . options) into a SQL column definition.
;; alter? toggles the ADD COLUMN constraint restrictions.
(define (column-spec->sql spec #!optional alter?)
  (let* ((col-name (car spec))
         (col-type (cadr spec))
         (options (cddr spec))
         (type-sql (column-type->sql col-type))
         (constraints (string-intersperse
                       (column-options->constraints options alter?) " ")))
    (conc (symbol->string col-name) " " type-sql
          (if (string=? constraints "") "" (conc " " constraints)))))

(define (model/schema/create-table table-name . column-specs)
  "Create table with column specifications"
  (let* ((columns-sql (map column-spec->sql column-specs))
         (sql (conc "CREATE TABLE " (symbol->string table-name) " ("
                    (string-intersperse columns-sql ", ") ")")))
    (db/execute sql)))

(define (model/schema/drop-table table-name)
  "Drop table"
  (let ((sql (conc "DROP TABLE " (symbol->string table-name))))
    (db/execute sql)))

(define (model/schema/add-columns table-name . column-specs)
  "Add columns to existing table.
   Honors the same options as create-table (default, not-null, foreign-key),
   subject to SQLite's ADD COLUMN restrictions: NOT NULL requires a non-NULL
   default, REFERENCES requires a NULL default, and PRIMARY KEY/UNIQUE/
   AUTOINCREMENT are rejected outright."
  (for-each
   (lambda (spec)
     (let ((sql (conc "ALTER TABLE " (symbol->string table-name)
                      " ADD COLUMN " (column-spec->sql spec #t))))
       (db/execute sql)))
   column-specs))

(define (model/schema/drop-columns table-name . column-names)
  "Drop columns from table (limited SQLite support)"
  (for-each
   (lambda (col-name)
     (let ((sql (conc "ALTER TABLE " table-name " DROP COLUMN " col-name)))
       (db/execute sql)))
   column-names))
)
