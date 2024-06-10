;;;
;;; parseopt.scm - yet another command-line argument parser
;;;
;;;   Copyright (c) 2000-2024  Shiro Kawai  <shiro@acm.org>
;;;
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;

(define-module gauche.parseopt
  (use util.match)
  (use text.tree)
  (export make-option-parser parse-options let-args
          <parseopt-error>
          option-parser-help-string))
(select-module gauche.parseopt)

;; text.fill depends on gauche.unicode, so delay loading it.  It's only used
;; to format help strings.
(autoload text.fill text->filled-stree)

;; This error is thrown when the given argument doesn't follow the spec.
;; (An error in the spec itself is thrown as an ordinary error.)
(define-condition-type <parseopt-error> <error> #f
  (option-name))

;; Represents each option info
(define-class <option-spec> ()
  ((short-names :init-keyword :short-names) ; one-character option names
   (long-names :init-keyword :long-names) ; multi-letter option names
   (args :init-keyword :args)        ; option agrspecs (list of chars)
   (arg-optional? :init-keyword :arg-optional?) ; option's arg optional?
   (handler :init-keyword :handler)  ; handler closure
   (plural? :init-keyword :plural?)  ; accept multiple options?
   (optspec :init-keyword :optspec)  ; original <optspec> string
   (help    :init-keyword :help)     ; help string
   ))

(define-method write-object ((obj <option-spec>) port)
  (format port "#<option-spec ~s ~s>"
          (~ obj'short-names) (~ obj'long-names)))

;; Manage all options, created by build-option-parser.  This is an
;; applicable object, in order to keep the backward compatibility.
(define-class <option-parser> ()
  ((option-specs :init-keyword :option-specs)
   (fallback :init-keyword :fallback)))

;; Parse optsepc and reurun <option-spec>.
(define (make-option-spec optspec help-string :optional (handler #f))
  ($ assume-type optspec <string>
     "String required for a command spec, but got:" optspec)
  ($ assume-type help-string (<?> <string>)
     "String required for a command help, but got:" help-string)
  (rxmatch-if (rxmatch #/^-*([-+\w|]+)(\*)?(?:([=:])(.+))?$/ optspec)
      (#f optnames plural? optional? argspec)
    (receive (shorts longs)
        (partition (^s (= (string-length s) 1)) (string-split optnames #\|))
      (make <option-spec>
        :short-names (map (cut string-ref <> 0) shorts)
        :long-names longs
        :args (if argspec
                (string->list (regexp-replace-all #/\{[^\}]+\}/ argspec ""))
                '())
        :arg-optional? (equal? optional? ":")
        :plural? plural?
        :optspec optspec
        :handler handler
        :help help-string))
    (error "unrecognized option spec:" optspec)))

;; Helper functions

(define (plural-option? spec)
  (assume-type spec <string>)           ;takes string spec
  (and-let1 m (rxmatch #/^-*[-+\w|]+(\*)?/ spec)
    (boolean (m 1))))

(define (optspec-take-args? optspec) (not (null? (~ optspec'args))))

;; Find an optspec that matches the given option.  Returns a pair of
;; <option-spec> and matching option string (without leading '-').
;; A special handling is needed for a single-letter option taking arguments;
;; fof such an option, we allow its argument to be concatenated with the
;; option itself; e.g. "I=s" spec can accept '-I arg', '-I=arg', and '-Iarg'.
(define (find-matching-optspec option optspecs)
  (define (optspec-long-match? optspec option)
    (let* ([optname (rxmatch->string #/^[^=]+/ option)]
           [spec (member optname (~ optspec'long-names))])
      (and spec (cons optspec optname))))
  (define (optspec-short-match? optspec option)
    (let* ([optchar (string-ref option 0)]
           [spec (memv optchar (~ optspec'short-names))])
      (and spec (cons optspec (string optchar)))))
  ;; It is imperative to search long option first, then search short options.
  ;; If we have "long" and "l=s", "--long" matches the first one, while
  ;; "-lfoo" matches the second one.
  (or (any (cut optspec-long-match? <> option) optspecs)
      (any (cut optspec-short-match? <> option) optspecs)))

;; From the args given at the command line, get a next option.
;; Returns option string (potentially followed by arg) and rest args.
(define (next-option args)
  (cond
   [(null? args) (values #f '())]
   [(string=? (car args) "--") (values #f (cdr args))]
   [(#/^--?(\w.*)/ (car args)) => (^m (values (m 1) (cdr args)))]
   [else (values #f args)]))

;; From the list of optarg spec and given command line arguments,
;; get a list of optargs.  Returns optargs and unconsumed args.
(define (get-optargs optspec optname option args)
  (define (get-number arg)
    (or (string->number arg)
        (errorf <parseopt-error> :option-name optname
                "a number is required for option ~a, but got ~a"
                optname arg)))
  (define (get-real arg)
    (or (and-let* ([num (string->number arg)]
                   [ (real? num) ])
          (exact->inexact num))
        (errorf <parseopt-error> :option-name optname
                "a real number is required for option ~a, but got ~a"
                optname arg)))
  (define (get-integer arg)
    (or (and-let* ([num (string->number arg)]
                   [ (exact? num) ])
          num)
        (errorf <parseopt-error> :option-name optname
                "an integer is required for option ~a, but got ~a"
                optname arg)))
  (define (get-sexp arg)
    (guard (e [(<read-error> e)
               (errorf <parseopt-error> :option-name optname
                       "the argument for option ~a is not valid sexp: ~s"
                       optname arg)])
      (read-from-string arg)))
  (define (process-args args)
    (let loop ([spec (~ optspec 'args)]
               [args args]
               [optargs '()])
      (cond [(null? spec) (values (reverse! optargs) args)]
            [(null? args) (error <parseopt-error> :option-name optname
                                 "running out the arguments for option"
                                 optname)]
            [else
             (case (car spec)
               [(#\s) (loop (cdr spec) (cdr args) (cons (car args) optargs))]
               [(#\n) (loop (cdr spec) (cdr args)
                            (cons (get-number (car args)) optargs))]
               [(#\f) (loop (cdr spec) (cdr args)
                            (cons (get-real (car args)) optargs))]
               [(#\i) (loop (cdr spec) (cdr args)
                            (cons (get-integer (car args)) optargs))]
               [(#\e) (loop (cdr spec) (cdr args)
                            (cons (get-sexp (car args)) optargs))]
               [(#\y) (loop (cdr spec) (cdr args)
                            (cons (string->symbol (car args)) optargs))]
               [else (error "unknown option argument spec:" (car spec))])])
      ))

  (cond [(and (#/^[^=]+=/ option))
         => (^m (let1 arg (rxmatch-after m)
                  (process-args (cons arg args))))]
        [(and (= (string-length optname) 1)
              (optspec-take-args? optspec)
              (> (string-length option) 1))
         ;; single-letter with concatenated argument
         (process-args (cons (substring option 1 (string-length option)) args))]
        [(~ optspec 'arg-optional?)
         (if (or (null? args)
                 (#/^-/ (car args)))
           (values (make-list (length (~ optspec 'args)) #f) args)
           (process-args args))]
        [else
         (process-args args)]))

;; Now, this is the argument parser body.
(define (parse-cmdargs args speclist fallback)
  (let loop ([args args])
    (receive (option nextargs) (next-option args)
      (if option
        (cond [(find-matching-optspec option speclist)
               => (^[spec&name]
                    (receive (optargs nextargs)
                        (get-optargs (car spec&name) (cdr spec&name)
                                     option nextargs)
                      (apply (~ (car spec&name)'handler) optargs)
                      (loop nextargs)))]
              ;; For unknown options including '=', we split at the first '='
              ;; and take the first part as an unknown option.  This is not
              ;; exactly the right thing; if we get "--unknown=--known" in
              ;; command line, where 'unknown' is an unknown option and
              ;; 'known' is a known option, this passes 'unknown' to the
              ;; fallback handler, but keep processing 'known' as an option.
              ;; However, we need this behavior for the backward compatibility.
              [(#/^([^=]+)=/ option)
               => (^m (fallback (m 1) (cons (m 'after) nextargs) loop))]
              [else (fallback option nextargs loop)])
        nextargs))))

;; Build
(define (build-option-parser specs fallback)
  (make <option-parser>
    :option-specs specs
    :fallback (or fallback default-fallback)))

(define-method object-apply ((parser <option-parser>) args)
  (parse-cmdargs args (~ parser'option-specs) (~ parser'fallback)))
(define-method object-apply ((parser <option-parser>) args fallback)
  (parse-cmdargs args (~ parser'option-specs) fallback))

(define (default-fallback option arg looper)
  (error <parseopt-error> :option-name #f
         "unrecognized option:" option))


;;;
;;; The main body of the macros
;;;

(define-syntax make-option-parser
  (syntax-rules ()
    [(_ clauses)
     (make-option-parser-int clauses ())]))

(define-syntax make-option-parser-int
  (syntax-rules (else =>)
    [(_ () specs)
     (build-option-parser (map %compose-entry (list . specs)) #f)]
    [(_ ((else args . body)) specs)
     (build-option-parser (map %compose-entry (list . specs)) (^ args . body))]
    [(_ ((else => proc)) specs)
     (build-option-parser (map %compose-entry (list . specs)) proc)]
    [(_ ((optspec => proc) . clause) (spec ...))
     (make-option-parser-int clause (spec ... (list 'optspec proc)))]
    [(_ ((optspec vars . body) . clause) (spec ...))
     (make-option-parser-int clause (spec ... (list 'optspec (^ vars . body))))]
    [(_ (other . clause) specs)
     (syntax-error "make-option-parser: malformed clause:" other)]
    ))

;; Parse optspec clause, and returns an <option-spec>.
;; <a-spec> is (<optspec> <handler>) or
;; ((<optspec> <help-string>) <handler>)
(define (%compose-entry a-spec)
  (define (parse-spec a-spec)
    (match a-spec
      [((spec help-string) handler) (values spec help-string handler)]
      [(spec handler) (values spec #f handler)]
      [_ (error "Invalid command-line argument specification:" a-spec)]))
  (receive (optspec helpstr handler) (parse-spec a-spec)
    (make-option-spec optspec helpstr handler)))

(define-syntax parse-options
  (syntax-rules ()
    [(_ args clauses)
     ((make-option-parser clauses) args)]))

;;;
;;; help string builder
;;;


(define *help-option-indent* 2)
(define *help-description-indent* 15)
(define *help-width* 75)

(define (option-parser-help-info option-parser)
  (map (^[spec] `(,(~ spec'optspec) ,(~ spec'help)))
       (~ option-parser'option-specs)))

(define (option-parser-help-string :key
                                   (option-parser (current-option-parser))
                                   (omit-options-without-help #f)
                                   (option-indent *help-option-indent*)
                                   (description-indent *help-description-indent*)
                                   (width *help-width*))
  ;; Convert optspec "a|abc=s{filename}"
  ;; into descriptive "-a, --abc filename"
  ;; If argument name {...} is not provided, use the type desc
  ;;  "a|abc=ss" => "-a, --abc s s"
  (define (optheader optspec)
    (let* ([opts (string-split optspec "|")]
           [lastopt&arg (string-split (last opts) #/\*?=/ 'infix 1)]
           [opts (append (drop-right opts 1) (take lastopt&arg 1))]
           [argdesc (if (pair? (cdr lastopt&arg))
                      (optarg-desc (cadr lastopt&arg))
                      '())])
      (tree->string
       (list ($ intersperse ", "
                (map (^[opt] (if (= (string-length opt) 1)
                               (format "-~a" opt)
                               (format "--~a" opt)))
                     opts))
             (map (^[arg] `(" " ,arg)) argdesc)))))

  (define (optarg-desc argspec)
    (cond [(equal? argspec "") '()]
          [(#/^([[:alpha:]])(?:\{([^\}]+)\})?/ argspec)
           => (^m (cons (or (m 2) (m 1)) (optarg-desc (m 'after))))]
          [else (error "invalid argspec:" argspec)]))

  (tree->string
   (filter-map (match-lambda
                 [(optspec help)
                  (if (and (not help) omit-options-without-help)
                    #f
                    `(,($ text->filled-stree
                          (if help
                            (regexp-replace-all #/\{([^\}]+)\}/ help (cut <> 1))
                            "(No help available)")
                          :lead-in (format "~va~a" option-indent ""
                                           (optheader optspec))
                          :indent description-indent
                          :width width)
                      "\n"))])
               (option-parser-help-info option-parser))))

;;;
;;; The alternative way : let-args
;;;   Based on Alex Shinn's implementation.
;;;

;; This parameter is bound to <option-parser> during evaluation of
;; callbacks and body.
(define current-option-parser (make-parameter #f))

;; (let-args args (varspec ...) body ...)
;;  where varspec can be
;;   (var spec [default] [? helpstring])
;;  or
;;   (var spec [default] => callback [? helpstring])
;;
;;  varspec can be an improper list, as
;;
;; (let-args args (varspec ... . rest) body ...)
;;
;;  then, rest is bound to the rest of the args.

(define-syntax let-args
  (er-macro-transformer
   (^[f r c]
     (define (else? x) (c (r'else) x))
     (define (=>? x)   (c (r'=>) x))
     (define (?? x)    (c (r'?) x))

     (define (xdef spec) (if (plural-option? spec) '() #f))
     (define (bad) (error "malformed let-args:" f))

     ;; Canonicalize variationof clauses.
     ;;   bindings: ((<var> <spec> <default> <helpstr> <handler-var> <handler>)
     ;;   else-handler: handler expression
     ;;   rest-var: #f or identifier
     (define (canon varspecs bindings)

       (define (next varspecs var spec default help callback)
         (canon varspecs
                `((,var ,spec ,default ,help
                        ,(and callback (gensym "handler")) ,callback)
                  ,@bindings)))

       (match varspecs
         ;; Terminal conditions
         [(? identifier? restvar) (values (reverse bindings) #f restvar)]
         [() (values (reverse bindings) #f (gensym "rest"))]
         [(((? else?) (? =>?) callback) . rest)
          (cond [(null? rest)
                 (values (reverse bindings) callback (gensym "rest"))]
                [(identifier? rest)
                 (values (reverse bindings) callback rest)]
                [else (bad)])]
         [(((? else?) formals expr ...) . rest)
          (cond [(null? rest)
                 (values (reverse bindings)
                         (quasirename r (^ ,formals ,@expr))
                         (gensym "rest"))]
                [(identifier? rest)
                 (values (reverse bindings)
                         (quasirename r (^ ,formals ,@expr))
                         rest)]
                [else (bad)])]
         ;; Loop with processing clauses
         [((var spec (? =>?) callback (? ??) help) . varspecs)
          (next varspecs var spec (xdef spec) help callback)]
         [((var spec default (? =>?) callback (? ??) help) . varspecs)
          (next varspecs var spec default help callback)]
         [((var spec (? =>?) callback) . varspecs)
          (next varspecs var spec (xdef spec) #f callback)]
         [((var spec default (? =>?) callback) . varspecs)
          (next varspecs var spec default #f callback)]
         [((var spec (? ??) help) . varspecs)
          (next varspecs var spec (xdef spec) help #f)]
         [((var spec default (? ??) help) . varspecs)
          (next varspecs var spec default help #f)]
         [((var spec default) . varspecs)
          (next varspecs var spec default #f #f)]
         [((var spec) . varspecs)
          (next varspecs var spec (xdef spec) #f #f)]
         [_ (bad)]))

     (define (var-bindings bindings else-var else-handler)
       `(,@(filter-map (match-lambda
                         [(var _ default . _) (and var `(,var ,default))])
                       bindings)
         ,@(filter-map (match-lambda
                         [(_ _ _ _ handler-var handler)
                          (and handler-var `(,handler-var ,handler))])
                       bindings)
         ,@(if else-var
             `((,else-var ,else-handler))
             '())))

     (define (gen-optspecs bindings)
       (map (match-lambda
              [(#f spec _ help #f _)
               (quasirename r
                 `(make-option-spec ',spec ',help (constantly #t)))]
              [(#f spec _ help handler-var _)
               (quasirename r
                 `(make-option-spec ',spec ',help ,handler-var))]
              [(var spec _ help #f _)
               (if (plural-option? spec)
                 (quasirename r
                   `(make-option-spec ',spec ',help
                                      (case-lambda
                                        [()    (push! ,var #t)]
                                        [(val) (push! ,var val)]
                                        [vals  (push! ,var vals)])))
                 (quasirename r
                   `(make-option-spec ',spec ',help
                                      (case-lambda
                                        [()    (set! ,var #t)]
                                        [(val) (set! ,var val)]
                                        [vals  (set! ,var vals)]))))]
              [(var spec _ help handler-var _)
               (quasirename r
                 `(make-option-spec ',spec ',help
                                    (^ args
                                      (set! ,var (apply ,handler-var args)))))]
              )
            bindings))

     ;; Main body
     (match (cdr f)
       [(args varspecs . body)
        (receive (bindings else-handler restvar) (canon varspecs '())
          (let1 else-var (and else-handler (gensym "else"))
            (quasirename r
              `(let ,(var-bindings bindings else-var else-handler)
                 (parameterize ((current-option-parser
                                 (build-option-parser
                                  (list ,@(gen-optspecs bindings))
                                  ,else-var)))
                   (let ((,restvar ((current-option-parser) ,args)))
                     ,@body))))))]
       [_ (bad)]))))
