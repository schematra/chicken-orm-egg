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
 make-model-scope
 model-scope?
 apply-model-scope-condition
 apply-model-scope-write
 make-model-hooks
 model-hooks?
 model-hooks-add!
 model-hooks-ref
 model-hooks-clear!
 model-hook-event?
 model-hook-events
 run-before-hooks
 run-after-hooks
 make-model-query
 model-query?
 q/where
 q/order
 q/limit
 q/offset
 q/first
 q/count
 q/then
 q/by-id
 q/run
 q/run-list
 q/run-all
 model/hook
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

;; Optional, application-defined policy attached to a model. The ORM knows
;; nothing about tenants (or any other policy): it only asks for a mandatory
;; query condition and lets the application prepare rows before writes.
(define-record-type model-scope
  (%make-model-scope condition-procedure write-procedure)
  model-scope?
  (condition-procedure model-scope-condition-procedure)
  (write-procedure model-scope-write-procedure))

(define (make-model-scope condition-procedure
                          #!optional (write-procedure (lambda (row) row)))
  (unless (procedure? condition-procedure)
    (error "model scope condition must be a procedure" condition-procedure))
  (unless (procedure? write-procedure)
    (error "model scope write preparation must be a procedure" write-procedure))
  (%make-model-scope condition-procedure write-procedure))

;; Combine the scope before the caller condition so placeholder values have a
;; deterministic order. A configured scope may never return #f: that would
;; silently turn a fail-closed model into an unscoped query.
(define (apply-model-scope-condition scope conditions query-values)
  (if (not scope)
      (values conditions query-values)
      (begin
        (unless (model-scope? scope)
          (error "invalid model scope" scope))
        (let-values (((scope-condition scope-values)
                      ((model-scope-condition-procedure scope))))
          (unless scope-condition
            (error "model scope condition procedure returned no condition"))
          (unless (list? scope-values)
            (error "model scope condition values must be a list" scope-values))
          (values (if conditions
                      `(and ,scope-condition ,conditions)
                      scope-condition)
                  (append scope-values query-values))))))

(define (apply-model-scope-write scope row)
  (if (not scope)
      row
      (begin
        (unless (model-scope? scope)
          (error "invalid model scope" scope))
        (let ((prepared ((model-scope-write-procedure scope) row)))
          (unless (list? prepared)
            (error "model scope write procedure must return a row alist" prepared))
          prepared))))

;; Lifecycle hooks. Unlike a model scope (one procedure, security boundary),
;; hooks are additive and multi-subscriber: any module holding (<table>/hooks)
;; can register ordinary application behavior. Hooks run *before* the scope's
;; write procedure, so the scope always gets the last word on a row.
(define *model-hook-events*
  '(before-create after-create
    before-save   after-save
    before-delete after-delete))

(define (model-hook-events) *model-hook-events*)

(define (model-hook-event? event)
  (and (memq event *model-hook-events*) #t))

(define-record-type model-hooks
  (%make-model-hooks alist)
  model-hooks?
  (alist model-hooks-alist model-hooks-alist-set!))

(define (make-model-hooks) (%make-model-hooks '()))

;; Appends, so registration order is run order.
(define (model-hooks-add! hooks event proc)
  (unless (model-hooks? hooks)
    (error "invalid model hooks" hooks))
  (unless (model-hook-event? event)
    (error "unknown model hook event" event))
  (unless (procedure? proc)
    (error "model hook must be a procedure" proc))
  (model-hooks-alist-set!
   hooks
   (alist-update event
                 (append (or (alist-ref event (model-hooks-alist hooks)) '())
                         (list proc))
                 (model-hooks-alist hooks)))
  proc)

(define (model-hooks-ref hooks event)
  (unless (model-hooks? hooks)
    (error "invalid model hooks" hooks))
  (or (alist-ref event (model-hooks-alist hooks)) '()))

(define (model-hooks-clear! hooks #!optional event)
  (unless (model-hooks? hooks)
    (error "invalid model hooks" hooks))
  (model-hooks-alist-set!
   hooks
   (if event
       (alist-update event '() (model-hooks-alist hooks))
       '())))

;; before-* hooks are a left fold: row-alist -> row-alist, in registration
;; order, each fed the previous one's output.
(define (run-before-hooks hooks event row)
  (if (not hooks)
      row
      (fold (lambda (proc acc)
              (let ((result (proc acc)))
                (unless (list? result)
                  (error "model hook must return a row alist" result))
                result))
            row
            (model-hooks-ref hooks event))))

;; after-* hooks are observers: they see the persisted row and their return
;; values are discarded. Folding them too would make one hook forgetting to
;; return the row corrupt what create/save hand back.
;;
;; A #f row means the post-write re-fetch found nothing, which happens when the
;; write landed outside the model's scope. After-hooks are skipped there; that
;; is hard to debug silently, so it warns. The row is returned either way, so
;; generated code can use this call as its tail expression. The warning has to
;; live here: `w` belongs to orm's module, not to the model's.
(define (run-after-hooks hooks event row)
  (cond
   ((not row)
    (w "skipping " event " hooks: row not visible after write (out of scope?)")
    row)
   ((not hooks) row)
   (else
    (for-each (lambda (proc) (proc row))
              (model-hooks-ref hooks event))
    row)))

;; Query descriptors. A model read is a value built with the q/ functions
;; and executed later by q/run (one statement) or q/run-list / q/run-all (one
;; db/batch, a single round trip on backends with native batching). Nothing
;; touches the database, or the model scope, until a runner renders it.
(define-record-type model-query
  (%make-model-query table columns scope conditions order limit offset shape thens)
  model-query?
  (table model-query-table)
  ;; thunk returning the model's column specs (i.e. users/columns)
  (columns model-query-columns)
  (scope model-query-scope)
  ;; list of (condition . values), in call order
  (conditions model-query-conditions)
  (order model-query-order)
  (limit model-query-limit)
  (offset model-query-offset)
  ;; rows | first | count
  (shape model-query-shape)
  ;; post-processing procedures, applied in order to the final value
  (thens model-query-thens))

(define (make-model-query table columns-thunk scope)
  (%make-model-query table columns-thunk scope '() #f #f #f 'rows '()))

(define (check-model-query q)
  (unless (model-query? q)
    (error "not a model query" q)))

;; Functional update: a copy of q with one field replaced.
(define (model-query-with q field value)
  (check-model-query q)
  (let ((get (lambda (name accessor)
               (if (eq? name field) value (accessor q)))))
    (%make-model-query (model-query-table q)
                       (model-query-columns q)
                       (model-query-scope q)
                       (get 'conditions model-query-conditions)
                       (get 'order model-query-order)
                       (get 'limit model-query-limit)
                       (get 'offset model-query-offset)
                       (get 'shape model-query-shape)
                       (get 'thens model-query-thens))))

;; Conditions given to several q/where calls are ANDed together.
(define (q/where q condition . vals)
  (check-model-query q)
  (model-query-with q 'conditions
                    (append (model-query-conditions q)
                            (list (cons condition vals)))))

;; order: field | (asc field) | (desc field)
(define (q/order q order) (model-query-with q 'order order))
(define (q/limit q n) (model-query-with q 'limit n))
(define (q/offset q n) (model-query-with q 'offset n))

;; Run as a single row: the first match as an alist, or #f.
(define (q/first q)
  (model-query-with (model-query-with q 'limit 1) 'shape 'first))

;; Run as the integer count of matching rows (order/limit/offset are ignored).
(define (q/count q) (model-query-with q 'shape 'count))

;; Post-process the final value; several q/then calls compose in order.
(define (q/then q proc)
  (unless (procedure? proc)
    (error "q/then expects a procedure" proc))
  (check-model-query q)
  (model-query-with q 'thens (append (model-query-thens q) (list proc))))

(define (q/by-id q id)
  (q/first (q/where q '(= id ?) id)))

;; Fold (condition . values) pairs into one condition (or #f) and its values.
(define (combine-query-conditions conditions)
  (cond
   ((null? conditions) (values #f '()))
   ((null? (cdr conditions)) (values (caar conditions) (cdar conditions)))
   (else (values `(and ,@(map car conditions))
                 (append-map cdr conditions)))))

;; order can be: symbol | (asc symbol) | (desc symbol). Model fields are
;; converted from kebab-case to snake_case, anything else passes through.
(define (convert-order-field order columns)
  (let ((convert (lambda (field)
                   (if (member field columns) (symbol->db-column field) field))))
    (cond
     ((not order) #f)
     ((list? order) (list (car order) (convert (cadr order))))
     (else (convert order)))))

;; Returns (values ssql params). The model scope is applied here, at run time
;; and last, so it is always ANDed in and its procedure sees the caller's
;; parameterize. A scope that cannot produce a condition fails closed.
(define (render-model-query q)
  (let-values (((conditions vals)
                (combine-query-conditions (model-query-conditions q))))
    (let-values (((scoped-conditions scoped-values)
                  (apply-model-scope-condition (model-query-scope q) conditions vals)))
      (let* ((columns (map car ((model-query-columns q))))
             (db-table-name (symbol->db-column (model-query-table q)))
             (where-part (if scoped-conditions
                             `((where ,(map-field-names->columns scoped-conditions columns)))
                             '())))
        (values
         (if (eq? (model-query-shape q) 'count)
             `(select (columns (as (count *) _count))
                (from ,db-table-name)
                ,@where-part)
             (let ((order (convert-order-field (model-query-order q) columns))
                   (limit (model-query-limit q))
                   (offset (model-query-offset q)))
               `(select (columns ,@(map symbol->db-column columns))
                  (from ,db-table-name)
                  ,@where-part
                  ,@(if order `((order ,order)) '())
                  ,@(if limit `((limit ,limit)) '())
                  ,@(if offset `((offset ,offset)) '()))))
         scoped-values)))))

;; Shape the raw row vector, then apply the q/then procedures.
(define (finalize-model-query q rows)
  (let ((single (and (vector? rows)
                     (> (vector-length rows) 0)
                     (vector-ref rows 0))))
    (fold (lambda (proc acc) (proc acc))
          (case (model-query-shape q)
            ((first) (and single (convert-result-keys single)))
            ((count) (if single (alist-ref '_count single) 0))
            (else (convert-results-vector rows)))
          (model-query-thens q))))

(define (q/run q)
  (check-model-query q)
  (let-values (((query params) (render-model-query q)))
    (finalize-model-query q (db/query query params))))

;; Everything is rendered before anything is sent, so a scope error in one
;; descriptor aborts the whole batch without a request.
(define (q/run-list qs)
  (for-each check-model-query qs)
  (let ((statements (map (lambda (q)
                           (call-with-values (lambda () (render-model-query q)) cons))
                         qs)))
    (map finalize-model-query qs (db/batch statements))))

(define (q/run-all . qs)
  (apply values (q/run-list qs)))

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
            (options (cddr x))
            (scope-expression
             (cond
              ((null? options) #f)
              ((and (= (length options) 2)
                    (eq? (car options) 'scope:))
               (cadr options))
              (else
               (error "define-model expects (define-model name [scope: scope])" x))))
            (table-name-str (symbol->string table-name))
            ;; Generate function names
            (load-metadata-name (string->symbol (conc table-name-str "/load-metadata")))
            (columns-name (string->symbol (conc table-name-str "/columns")))
            (pkey-name (string->symbol (conc table-name-str "/pkey")))
            (q-name (string->symbol (conc table-name-str "/q")))
            (create-name (string->symbol (conc table-name-str "/create")))
            (save-name (string->symbol (conc table-name-str "/save")))
            (update-name (string->symbol (conc table-name-str "/update")))
            (delete-name (string->symbol (conc table-name-str "/delete")))
	    (scope-name (string->symbol (conc table-name-str "/%scope")))
	    (hooks-name (string->symbol (conc table-name-str "/hooks")))
	    (hooks-var-name (string->symbol (conc table-name-str "/%hooks")))
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
          ,q-name ,create-name ,save-name ,update-name ,delete-name
          ,hooks-name)

         ;; Scope policy is private to the model's module. #f preserves the
         ;; historical behavior for every existing define-model call.
         (,%define ,scope-name ,scope-expression)

         ;; Lifecycle hooks. A plain define, so reloading this file rebinds a
         ;; fresh record and any model/hook forms below re-register exactly once.
         (,%define ,hooks-var-name (make-model-hooks))
         (,%define (,hooks-name) ,hooks-var-name)

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

         ;; Query descriptor for this model: build with q/where, q/order,
         ;; ..., run with q/run or q/run-all. The scope applies at run time.
         (,%define (,q-name)
                   (make-model-query ',table-name ,columns-name ,scope-name))

         ;; Create function - takes alist, returns alist of created row
         (,%define (,create-name row-alist)
		   (,%let* ((hooked-row (run-before-hooks ,hooks-var-name 'before-create row-alist))
			    ;; the scope is the security boundary, so it writes last
			    (prepared-row (apply-model-scope-write ,scope-name hooked-row))
			    (columns (,columns-name))
			    (db-columns (,%map (,(r 'lambda) (col-spec)
						(symbol->db-column (,%car col-spec))) columns))
			    (filtered-alist (,(r 'filter) (,(r 'lambda) (pair)
							   (,(r 'not) (,(r 'null?) (,(r 'cdr) pair)))) prepared-row))
			    (insert-columns (,%map (,(r 'lambda) (pair) (symbol->db-column (,(r 'car) pair))) filtered-alist))
			    (values (,%map ,(r 'cdr) filtered-alist))
			    (placeholders (,(r 'make-list) (,(r 'length) values) '?))
			    (db-table-name (symbol->db-column ',table-name))
			    (query `(insert (into ,db-table-name)
					    (columns ,@insert-columns)
					    (values #(,@placeholders))))
			    (new_id (db/execute query values 'last_insert_id))
			    ;; Re-read the created row by its new ID. This goes
			    ;; through the model query, so it is scoped: an out-of-scope
			    ;; insert comes back #f and after-create is skipped.
			    (created-row (q/run (q/first (q/where (,q-name) '(= rowid ?) new_id)))))
			   ;; returns created-row, and warns instead of running the
			   ;; hooks when the insert landed outside the scope
			   (run-after-hooks ,hooks-var-name 'after-create created-row)))

         ;; Save function - takes alist, updates existing row
         (,%define (,save-name row-alist)
	           (,%let* ((hooked-row (run-before-hooks ,hooks-var-name 'before-save row-alist))
		            ;; the scope is the security boundary, so it writes last
		            (prepared-row (apply-model-scope-write ,scope-name hooked-row))
		            (columns (,columns-name))
		            (pk-columns (get-primary-key-columns columns)))
	                   (,(r 'let-values) (((pk-where pk-values)
			                       (build-pk-where pk-columns prepared-row)))
	                    (,(r 'let-values) (((scoped-where scoped-values)
			                         (apply-model-scope-condition ,scope-name pk-where pk-values)))
	                    (,%let* ((non-pk-pairs (,(r 'filter) (,(r 'lambda) (pair)
						                  (,%let ((col-name (,(r 'car) pair)))
							                 (,(r 'and)
							                  ;; Not a primary key column
							                  (,(r 'not) (,(r 'any) (,(r 'lambda) (pk-col)
										                 (,(r 'eq?) col-name (,(r 'car) pk-col)))
								                      pk-columns))
							                  ;; Not a timestamp column (updated_at, created_at)
							                  (,(r 'not) (,(r 'memq) col-name '(updated-at created-at))))))
                                                    prepared-row))
		                     (set-clauses (,%map (,(r 'lambda) (pair)
						          `(,(symbol->db-column (,(r 'car) pair)) ?))
					                 non-pk-pairs))
		                     (set-values (,%map ,(r 'cdr) non-pk-pairs))
		                     (all-values (,(r 'append) set-values scoped-values))
		                     (db-table-name (symbol->db-column ',table-name))
		                     (query `(update ,db-table-name
				                     (set ,@set-clauses (updated_at CURRENT_TIMESTAMP))
				                     (where ,(map-field-names->columns scoped-where (,%map ,%car columns))))))
		                    (db/execute query all-values)
                                    ;; return a fresh version, because some fields might update on save
                                    ;; returns the re-fetched row, or #f (with a
                                    ;; warning, hooks skipped) if the scoped
                                    ;; UPDATE matched nothing
                                    (run-after-hooks
                                     ,hooks-var-name 'after-save
                                     (q/run (q/by-id (,q-name) (,(r 'alist-ref) 'id prepared-row)))))))))

         ;; update function, wrapper around lookup by id -> save
         (,%define (,update-name id updates)
                   (,%let ((row (q/run (q/by-id (,q-name) id))))
                          (,%if row
                                (,save-name (,(r 'fold) (,(r 'lambda) (pair acc)
                                                          (,(r 'alist-update) (,(r 'car) pair) (,(r 'cdr) pair) acc))
                                             row
                                             updates))
                                #f)))

         ;; Delete function - takes alist, deletes the row
         (,%define (,delete-name row-alist)
		   ;; before-delete is a fold like every other before-* hook, so the
		   ;; PK for the DELETE comes from whatever the hooks returned.
		   (,%let ((hooked-row (run-before-hooks ,hooks-var-name 'before-delete row-alist)))
		   (,(r 'let-values) (((pk-where pk-values)
				       (,%let* ((columns (,columns-name))
						(pk-columns (get-primary-key-columns columns)))
					       (build-pk-where pk-columns hooked-row))))
		    (,(r 'let-values) (((scoped-where scoped-values)
			                 (apply-model-scope-condition ,scope-name pk-where pk-values)))
		    (,%let* ((columns (,%map ,%car (,columns-name)))
			     (db-table-name (symbol->db-column ',table-name))
			     (query `(delete (from ,db-table-name)
			                    (where ,(map-field-names->columns scoped-where columns)))))
			    (db/execute query scoped-values)
			    ;; delete ignores rows_affected and always returns #t,
			    ;; so after-delete fires even on a no-op delete.
			    (run-after-hooks ,hooks-var-name 'after-delete hooked-row)
			    #t)))))
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
            (parent-get-children-name (string->symbol (conc parent-str "/" child-str "/q")))
            (child-get-parent-name (string->symbol (conc child-str "/" parent-str "/q")))
            (parent-add-child-name (string->symbol (conc parent-str "/add-" child-str)))
            (parent-q-name (string->symbol (conc parent-str "/q")))
            (child-q-name (string->symbol (conc child-str "/q")))
            (child-save-name (string->symbol (conc child-str "/save")))
	    (%let  (r 'let))
	    (%let* (r 'let*)))

       `(,(r 'begin)
         ;; Export relationship functions
         (,(r 'export) ,parent-get-children-name ,child-get-parent-name ,parent-add-child-name)

         ;; Parent -> Children (e.g., users/sessions/q) - a query descriptor
         ;; for the child rows; refine it with q/ and run it with q/run.
         (,(r 'define) (,parent-get-children-name parent-row)
          (q/where (,child-q-name) '(= ,fk-column ?) (,(r 'alist-ref) 'id parent-row)))

         ;; Child -> Parent (e.g., sessions/user/q) - a q/first descriptor, so it
         ;; runs to a single row or #f. A missing (or NULL) foreign key still
         ;; yields a descriptor, one that matches nothing, so it stays batchable.
         (,(r 'define) (,child-get-parent-name child-row)
          (,%let ((fk-value (,(r 'alist-ref) ',fk-column child-row)))
		 (,(r 'if) (,(r 'and) fk-value
                            (,(r 'not) (,(r 'eq?) fk-value 'null))
                            (,(r 'not) (,(r 'sql-null?) fk-value)))
                  (q/by-id (,parent-q-name) fk-value)
                  (q/first (q/where (,parent-q-name) '(= 1 0))))))

         ;; Add relationship (e.g., users/add-session)
         (,(r 'define) (,parent-add-child-name parent-row child-row)
          (,%let* ((parent-pk (,(r 'alist-ref) 'id parent-row))
                   (updated-child (,(r 'alist-update) ',fk-column parent-pk child-row)))
		  (,child-save-name updated-child))))))))

;; Lifecycle hook sugar:
;;   (model/hook users (before-create row) body ...)
;;   (model/hook users ((before-create before-save) row) body ...)
;; expands to a single closure registered against (users/hooks) for each event.
;; The event symbol cannot be validated here (the event list is a runtime
;; binding); model-hooks-add! validates it at the registering module's load time.
(define-syntax model/hook
  (er-macro-transformer
   (lambda (x r c)
     (let* ((table-name (cadr x))
            (head (caddr x))
            (body (cdddr x)))
       (unless (and (list? head) (= (length head) 2))
         (error "model/hook expects (model/hook table (event row) body ...)" x))
       (let* ((event-spec (car head))
              (formal (cadr head))
              (events (if (list? event-spec) event-spec (list event-spec))))
         (unless (symbol? formal)
           (error "model/hook row parameter must be a symbol" formal))
         (when (null? events)
           (error "model/hook needs at least one event" x))
         (for-each (lambda (event)
                     (unless (symbol? event)
                       (error "model/hook events must be symbols" event-spec)))
                   events)
         (when (null? body)
           (error "model/hook needs a body" x))
         (let ((hooks-name (string->symbol
                            (conc (symbol->string table-name) "/hooks")))
               (%hook (r 'hook)))
           ;; hooks-name splices unrenamed so it resolves in the use-site module;
           ;; the formal and body are user source and splice unrenamed too.
           `(,(r 'let) ((,%hook (,(r 'lambda) (,formal) ,@body)))
             ,@(map (lambda (event)
                      `(,(r 'model-hooks-add!) (,hooks-name) ',event ,%hook))
                    events))))))))

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
