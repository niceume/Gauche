;;
;; testing macro expansion
;;

(use gauche.test)

(test-start "macro")

;; strip off syntactic information from identifiers in the macro output.
(define (unident form)
  (cond
   ((identifier? form) (identifier->symbol form))
   ((pair? form) (cons (unident (car form)) (unident (cdr form))))
   ((vector? form)
    (list->vector (map unident (vector->list form))))
   (else form)))

(define-macro (test-macro msg expect form)
  `(test ,msg ',expect (lambda () (unident (%macroexpand ,form)))))

;;----------------------------------------------------------------------
;;

(test-section "ER macro basics")

(define-syntax er-when
  (er-macro-transformer
   (^[f r c]
     (let ([test (cadr f)]
           [exprs (cddr f)])
       `(,(r 'if) ,test (,(r 'begin) ,@exprs))))))

(test "when - basic" #t (^[] (let ((x #f)) (er-when #t (set! x #t)) x)))
(test "when - basic" #f (^[] (let ((x #f)) (er-when #f (set! x #t)) x)))

(test "when - hygene" 3
      (^[] (let ([if list]
                 [begin list])
             (er-when #t 1 2 3))))

(define-syntax er-aif
  (er-macro-transformer
   (^[f r c]
     (let ([test (cadr f)]
           [then (caddr f)]
           [else (cadddr f)])
       `(,(r 'let) ((it ,test))
           (,(r 'if) it ,then ,else))))))

(test "aif - basic" 4 (^[] (er-aif (+ 1 2) (+ it 1) #f)))
(test "aif - basic" 5 (^[] (let ((it 999)) (er-aif (+ 1 2) (+ it 2) #f))))

(test "aif - hygene" 6
      (^[] (let ((it 999)
                 (let list))
             (er-aif (+ 1 2) (+ it 3) #f))))
(test "aif - nesting" #t
      (^[] (let ([it 999])
             (er-aif (+ 1 2) (er-aif (odd? it) it #f) #f))))

(test-section "ER macro local scope")

(let ([if list])
  (let-syntax ([fake-if (er-macro-transformer
                         (^[f r c] `(,(r 'if) ,@(cdr f))))])
    (test "fake-if" '(1 2 3) (^[] (fake-if 1 2 3)))
    (let ([if +])
      (test "fake-if" '(4 5 6) (^[] (fake-if 4 5 6))))))

(test-section "ER compare literals")

;; from Clinger "Hygienic Macros Through Explicit Renaming"
(define-syntax er-cond
  (er-macro-transformer
   (^[f r c]
     (let1 clauses (cdr f)
       (if (null? clauses)
         `(,(r 'quote) ,(r 'unspecified))
         (let* ([first (car clauses)]
                [rest  (cdr clauses)]
                [test  (car first)])
           (cond [(and (identifier? test)
                       (c test (r 'else)))
                  `(,(r 'begin) ,@(cdr first))]
                 [else `(,(r 'if) ,test
                         (,(r 'begin) ,@(cdr first))
                         (er-cond ,@rest))])))))))

(define (er-cond-tester1 x)
  (er-cond [(odd? x) 'odd] [else 'even]))

(test "er-cond 1" '(even odd)
      (^[] (list (er-cond-tester1 0) (er-cond-tester1 1))))

(let ([else #f])
  (define (er-cond-tester2 x)
    (er-cond [(odd? x) 'odd] [else 'even]))
  (test "er-cond 2" '(unspecified odd)
        (^[] (list (er-cond-tester2 0) (er-cond-tester2 1)))))

(define-module er-test-mod
  (export er-cond2)
  (define-syntax er-cond2
    (er-macro-transformer
     (^[f r c]
       (let1 clauses (cdr f)
         (if (null? clauses)
           `(,(r 'quote) ,(r 'unspecified))
           (let* ([first (car clauses)]
                  [rest  (cdr clauses)]
                  [test  (car first)])
             (cond [(and (identifier? test)
                         (c test (r 'else)))
                    `(,(r 'begin) ,@(cdr first))]
                   [else `(,(r 'if) ,test
                           (,(r 'begin) ,@(cdr first))
                           (er-cond2 ,@rest))]))))))))

(define-module er-test-mod2
  (use gauche.test)
  (import er-test-mod)
  (define (er-cond-tester1 x)
    (er-cond2 [(odd? x) 'odd] [else 'even]))
  (test "er-cond (cross-module)" '(even odd)
        (^[] (list (er-cond-tester1 0) (er-cond-tester1 1)))))

;; Introducing local bindings
(let ((x 3))
  (let-syntax ([foo (er-macro-transformer
                     (^[f r c]
                       (let1 body (cdr f)
                         `(,(r 'let) ([,(r 'x) (,(r '+) ,(r 'x) 2)])
                           (,(r '+) ,(r 'x) ,@body)))))])
    (let ((x -1))
      (test* "er-macro introducing local bindings" 4
             (foo x)))))

;; er-macro and nested identifier
;; cf. http://saito.hatenablog.jp/entry/2014/11/18/233209
(define (er-test-traverse proc obj)
  (let loop ((obj obj))
    (cond [(identifier? obj) (proc obj)]
          [(pair? obj)   (cons (loop (car obj)) (loop (cdr obj)))]
          [(vector? obj) (vector-map loop obj)]
          [else obj])))

(define-syntax er-test-let/scope
  (er-macro-transformer
   (lambda (form rename _)
     (let ([scope (cadr form)]
           [body (cddr form)])
       `(let-syntax ((,scope
                      (,(rename 'er-macro-transformer)
                       (,(rename 'lambda) (f r _)
                        (,(rename 'let) ((form2 (,(rename 'cdr) f)))
                         (,(rename 'cons)
                          ',(rename 'begin)
                          (,(rename 'er-test-traverse) r form2)))))))
          ,@body)))))

(test "er-macro and nested identifier"
      '(2 2 3 4)
      (lambda ()
        (let ([x 1])
          (er-test-let/scope scope-1
            (let ([x 2])
              (er-test-let/scope scope-2
                (let ([x 3])
                  (er-test-let/scope scope-1
                    (let ([x 4])
                      (list (scope-2 (scope-1 x))
                            (scope-2 x)
                            (scope-1 x)
                            x))))))))))

;; passing form rename procedure
(let ([a 1] [b 2])
  (let-syntax ([foo (er-macro-transformer
                     (lambda (f r c)
                       (r '(cons (list a b) `#(,a ,b)))))])
    (let ([a -1] [b -2] [list *])
      (test* "list arg for rename procedure"
             '((1 2) . #(1 2))
             (foo)))))

;; er-macro and with-module
;; cf. https://github.com/shirok/Gauche/issues/250
(define er-macro-scope-test-a 'a)

(define-module er-macro-test-1
  (define er-macro-scope-test-a 'b))

(with-module er-macro-test-1
  (define-syntax er-macro-test-x
    (er-macro-transformer
     (^[f r c] (r 'er-macro-scope-test-a)))))

(test* "er-macro and with-module" 'b
       ((with-module er-macro-test-1 er-macro-test-x)))

;; er-macro and eval
(test* "er-macro and eval" 'b
       (eval '(let-syntax ((m (er-macro-transformer
                               (^[f r c] (r 'er-macro-scope-test-a)))))
                (m))
             (find-module 'er-macro-test-1)))

;; quasirename
(let ((unquote list)
      (x 1)
      (y 2))
  (let-syntax ([foo (er-macro-transformer
                     (^[f r c]
                       (let ([a (cadr f)]
                             [b (caddr f)]
                             [all (cdr f)])
                         (quasirename r
                           `(list x ,a y ,b ,@all
                                  '#(x ,a y ,b) ,@(reverse all))))))])
    (let ((list vector)
          (x 10)
          (y 20))
      (test* "er-macro and quasirename"
             '(1 3 2 4 3 4 #(x 3 y 4) 4 3)
             (foo 3 4)))))

;; nested quasirename
(let ()
  (define (add-prefix p)
    (^s (symbol-append p s)))
  (define a 1)
  (define b 2)
  (define c 3)
  (test* "nested quasirename"
         '(p:quasirename p:x
            `(p:a ,p:b ,(p:quote 3) ,d))
         (unwrap-syntax
          (quasirename (add-prefix 'p:)
            `(quasirename x
               `(a ,b ,',c ,,'d))))))

(let-syntax ([def (er-macro-transformer
                   (^[f r c]
                     (quasirename r
                       `(define-syntax ,(cadr f)
                          (er-macro-transformer
                           ;; we need to protect ff from being renamed,
                           ;; for we have to refer to it inside quote
                           ;; in (cadr ff).
                           (^[,'ff rr cc]
                             (quasirename rr
                               `(define ,',(caddr f) ,,'(cadr ff)))))))))])
  (test* "nested quasirename" 4
         (let ()
           (def foo bar)
           (let ()
             (foo 4)
             bar))))

;; Mixing syntax-rules and er-macro requires unhygienic identifiers to be
;; explicitly "injected".
;; (This does not work with the current compiler)

;; (define-syntax eri-test-loop
;;   (eri-macro-transformer
;;    (lambda (x r c i)
;;      (let ((body (cdr x)))
;;        `(,(r 'call-with-current-continuation)
;;          (,(r 'lambda) (,(i 'exiit))
;;           (,(r 'let) ,(r 'f) () ,@body (,(r 'f)))))))))

;; (define-syntax eri-test-foo
;;   (syntax-rules ()
;;     ((_ x) (eri-test-loop (exiit x)))))

;; (test* "Mixing syntax-rules and eri-macro" 'yot
;;        (let ((exiit 42))
;;          (eri-test-foo exiit)))

;;----------------------------------------------------------------------
;; er identifier macros
;;  EXPERIMENTAL - The interface of er-macro-transformer may change

(test-section "er identifier macros")

;; global
(define-module id-macro-test-er
  (use gauche.test)
  (define p (cons 4 5))
  (define-syntax p.car
    (make-id-transformer
     (er-macro-transformer
      (lambda (f r c)
        (cond [(identifier? f) (quasirename r `(car p))]
              [(c (car f) (r'set!))
               (quasirename r `(set-car! p ,(caddr f)))]
              [else (error "bad id-macro call:" f)])))))
  (test "er global identifier macro" 4 (lambda () p.car))
  (set! p.car 15)
  (test "er global identifier macro" 15 (lambda () p.car))
  (test "er global identifier macro" '(15 . 5) (lambda () p))

  (let ((p (cons 6 7)))
    (test "er global identifier macro hygiene" 15 (lambda () p.car))
    (set! p.car 99)
    (test "er global identifier macro hygiene" 99 (lambda () p.car))
    (test "er global identifier macro hygiene" '(6 . 7) (lambda () p)))

  (set! p.car list)
  (test "er global identifier macro in head" '(1 2 3) (lambda () (p.car 1 2 3)))
  )

(define-module id-macro-test-sr
  (use gauche.test)
  (define p (cons 4 5))
  (define-syntax p.car
    (make-id-transformer
     (syntax-rules (set!)
       [(set! _ expr) (set-car! p expr)]
       [_ (car p)])))

  (test "synrule global identifier macro" 4 (lambda () p.car))
  (set! p.car 15)
  (test "synrule global identifier macro" 15 (lambda () p.car))
  (test "synrule global identifier macro" '(15 . 5) (lambda () p))

  (let ((p (cons 6 7)))
    (test "synrule global identifier macro hygiene" 15 (lambda () p.car))
    (set! p.car 99)
    (test "synrule global identifier macro hygiene" 99 (lambda () p.car))
    (test "synrule global identifier macro hygiene" '(6 . 7) (lambda () p)))
  )

;; local
(let ((p (cons 4 5)))
  (let-syntax ((p.car
                (make-id-transformer
                 (er-macro-transformer
                  (lambda (f r c)
                    (cond [(identifier? f) (quasirename r `(car p))]
                          [(c (car f) (r'set!))
                           (quasirename r `(set-car! p ,(caddr f)))]
                          [else (error "bad id-macro call:" f)]))))))
  (test "er local identifier macro" 4 (lambda () p.car))
  (set! p.car 15)
  (test "er local identifier macro" 15 (lambda () p.car))
  (test "er local identifier macro" '(15 . 5) (lambda () p))

  (let ((p (cons 6 7)))
    (test "er local identifier macro hygiene" 15 (lambda () p.car))
    (set! p.car 99)
    (test "er local identifier macro hygiene" 99 (lambda () p.car))
    (test "er local identifier macro hygiene" '(6 . 7) (lambda () p)))

  (set! p.car list)
  (test "er local identifier macro in head" '(1 2 3) (lambda () (p.car 1 2 3)))
  ))

;;----------------------------------------------------------------------
;; basic tests

(test-section "basic expansion")

(define-syntax simple (syntax-rules ()
                        ((_ "a" ?a) (a ?a))
                        ((_ "b" ?a) (b ?a))
                        ((_ #f ?a)  (c ?a))
                        ((_ (#\a #\b) ?a) (d ?a))
                        ((_ #(1 2) ?a) (e ?a))
                        ((_ ?b ?a)  (f ?a ?b))))

(test-macro "simple" (a z) (simple "a" z))
(test-macro "simple" (b z) (simple "b" z))
(test-macro "simple" (c z) (simple #f z))
(test-macro "simple" (d z) (simple (#\a #\b) z))
(test-macro "simple" (e z) (simple #(1 2) z))
(test-macro "simple" (f z #(1.0 2.0)) (simple #(1.0 2.0) z))
(test-macro "simple" (f z (#\b #\a)) (simple (#\b #\a) z))
(test-macro "simple" (f z #(2 1)) (simple #(2 1) z))

(define-syntax underbar (syntax-rules ()
                          [(_) 0]
                          [(_ _) 1]
                          [(_ _ _) 2]
                          [(_ _ _ _) 3]
                          [(_ _ _ _ . _) many]))
(test-macro "underbar" 0 (underbar))
(test-macro "underbar" 1 (underbar a))
(test-macro "underbar" 2 (underbar a b))
(test-macro "underbar" 3 (underbar a b c))
(test-macro "underbar" many (underbar a b c d))

(define-syntax repeat (syntax-rules ()
                        ((_ 0 (?a ?b) ...)     ((?a ...) (?b ...)))
                        ((_ 1 (?a ?b) ...)     (?a ... ?b ...))
                        ((_ 2 (?a ?b) ...)     (?a ... ?b ... ?a ...))
                        ((_ 0 (?a ?b ?c) ...)  ((?a ...) (?b ?c) ...))
                        ((_ 1 (?a ?b ?c) ...)  (?a ... (?c 8 ?b) ...))
                        ))

(test-macro "repeat" ((a c e) (b d f))
            (repeat 0 (a b) (c d) (e f)))
(test-macro "repeat" (a c e b d f)
            (repeat 1 (a b) (c d) (e f)))
(test-macro "repeat" (a c e b d f a c e)
            (repeat 2 (a b) (c d) (e f)))
(test-macro "repeat" ((a d g) (b c) (e f) (h i))
            (repeat 0 (a b c) (d e f) (g h i)))
(test-macro "repeat" (a d g (c 8 b) (f 8 e) (i 8 h))
            (repeat 1 (a b c) (d e f) (g h i)))

(define-syntax repeat2 (syntax-rules () ;r7rs
                         ((_ 0 (?a ?b ... ?c))    (?a (?b ...) ?c))
                         ((_ 1 (?a ?b ... ?c ?d)) (?a (?b ...) ?c ?d))
                         ((_ 2 (?a ?b ... . ?c))  (?a (?b ...) ?c))
                         ((_ 3 (?a ?b ... ?c ?d . ?e))  (?a (?b ...) ?c ?d ?e))
                         ((_ ?x ?y) ho)))

(test-macro "repeat2" (a (b c d e f) g)
            (repeat2 0 (a b c d e f g)))
(test-macro "repeat2" (a () b)
            (repeat2 0 (a b)))
(test-macro "repeat2" ho
            (repeat2 0 (a)))
(test-macro "repeat2" (a (b c d e) f g)
            (repeat2 1 (a b c d e f g)))
(test-macro "repeat2" (a () b c)
            (repeat2 1 (a b c)))
(test-macro "repeat2" ho
            (repeat2 1 (a b)))
(test-macro "repeat2" (a (b c d e f g) ())
            (repeat2 2 (a b c d e f g)))
(test-macro "repeat2" (a (b c d e) f g ())
            (repeat2 3 (a b c d e f g)))
(test-macro "repeat2" (a (b c d) e)
            (repeat2 2 (a b c d . e)))
(test-macro "repeat2" (a (b) c d e)
            (repeat2 3 (a b c d . e)))

(define-syntax nest1 (syntax-rules ()
                       ((_ (?a ...) ...)        ((?a ... z) ...))))

(test-macro "nest1" ((a z) (b c d z) (e f g h i z) (z) (j z))
            (nest1 (a) (b c d) (e f g h i) () (j)))

(define-syntax nest2 (syntax-rules ()
                       ((_ ((?a ?b) ...) ...)   ((?a ... ?b ...) ...))))

(test-macro "nest2" ((a c b d) () (e g i f h j))
            (nest2 ((a b) (c d)) () ((e f) (g h) (i j))))

(define-syntax nest3 (syntax-rules ()
                       ((_ ((?a ?b ...) ...) ...) ((((?b ...) ...) ...)
                                                   ((?a ...) ...)))))

(test-macro "nest3" ((((b c d e) (g h i)) (() (l m n) (p)) () ((r)))
                     ((a f) (j k o) () (q)))
            (nest3 ((a b c d e) (f g h i)) ((j) (k l m n) (o p)) () ((q r))))

(define-syntax nest4 (syntax-rules () ; r7rs
                       ((_ ((?a ?b ... ?c) ... ?d))
                        ((?a ...) ((?b ...) ...) (?c ...) ?d))))

(test-macro "nest4"((a d f)
                    ((b) () (g h i))
                    (c e j)
                    (k l m))
            (nest4 ((a b c) (d e) (f g h i j) (k l m))))

(define-syntax nest5 (syntax-rules () ; r7rs
                       ((_ (?a (?b ... ?c ?d) ... . ?e))
                        (?a ((?b ...) ...) (?c ...) (?d ...) ?e))))
(test-macro "nest5" (z
                     ((a) (d e) ())
                     (b f h)
                     (c g i)
                     j)
            (nest5 (z (a b c) (d e f g) (h i) . j)))

(define-syntax nest6 (syntax-rules ()
                       ((_ (?a ...) ...)
                        (?a ... ...)))) ;SRFI-149
(test-macro "nest6" (a b c d e f g h i j)
            (nest6 (a b c d) (e f g) (h i) (j)))
(test-macro "nest6" (a b c d e f g)
            (nest6 (a b c d) () (e) () (f g)))

(define-syntax nest7 (syntax-rules ()
                       ((_ (?a ...) ...)
                        (?a ... ... z ?a ... ...)))) ;SRFI-149
(test-macro "nest7" (a b c d e f g h i j z a b c d e f g h i j)
            (nest7 (a b c d) (e f g) (h i) (j)))
(test-macro "nest7" (a b c d e f g z a b c d e f g)
            (nest7 (a b c d) () (e) () (f g)))

(define-syntax nest8 (syntax-rules ()
                       ((_ ((?a ...) ...) ...)
                        (?a ... ... ... z)))) ;SRFI-149
(test-macro "nest8" (a b c d e f g h i j z)
            (nest8 ((a b c d) (e f g)) ((h i) (j))))
(test-macro "nest8" (a b c d e f g h i j z)
            (nest8 ((a b c d) () (e f g)) () ((h i) () (j) ())))

;; mixlevel is allowed by SRFI-149
(define-syntax mixlevel1 (syntax-rules ()
                           ((_ (?a ?b ...)) ((?a ?b) ...))))

(test-macro "mixlevel1" ((1 2) (1 3) (1 4) (1 5) (1 6))
            (mixlevel1 (1 2 3 4 5 6)))
(test-macro "mixlevel1" ()
            (mixlevel1 (1)))

(define-syntax mixlevel2 (syntax-rules ()
                           ((_ (?a ?b ...) ...)
                            (((?a ?b) ...) ...))))

(test-macro "mixlevel2" (((1 2) (1 3) (1 4)) ((2 3) (2 4) (2 5) (2 6)))
            (mixlevel2 (1 2 3 4) (2 3 4 5 6)))

(define-syntax mixlevel3 (syntax-rules ()
                           ((_ ?a (?b ?c ...) ...)
                            (((?a ?b ?c) ...) ...))))

(test-macro "mixlevel3" (((1 2 3) (1 2 4) (1 2 5) (1 2 6))
                         ((1 7 8) (1 7 9) (1 7 10)))
            (mixlevel3 1 (2 3 4 5 6) (7 8 9 10)))

;; test that wrong usage of ellipsis is correctly identified
(test "bad ellipsis 1" (test-error)
      (lambda ()
        (eval '(define-syntax badellipsis
                 (syntax-rules () [(t) (3 ...)]))
              (interaction-environment))))
(test "bad ellipsis 2" (test-error)
      (lambda ()
        (eval '(define-syntax badellipsis
                 (syntax-rules () [(t a) (a ...)]))
              (interaction-environment))))
(test "bad ellipsis 3" (test-error)
      (lambda ()
        (eval '(define-syntax badellipsis
                 (syntax-rules () [(t a b ...) (a ...)]))
              (interaction-environment))))
(test "bad ellipsis 4" (test-error)
      (lambda ()
        (eval '(define-syntax badellipsis
                 (syntax-rules () [(t a ...) ((a ...) ...)]))
              (interaction-environment))))

(test "bad ellipsis 5" (test-error)
      (lambda ()
        (eval '(define-syntax badellipsis
                 (syntax-rules () [(t (a ... b ...)) ((a ...) (b ...))]))
              (interaction-environment))))
(test "bad ellipsis 6" (test-error)
      (lambda ()
        (eval '(define-syntax badellipsis
                 (syntax-rules () [(t (... a b)) (... a b )]))
              (interaction-environment))))

(define-syntax hygiene (syntax-rules ()
                         ((_ ?a) (+ ?a 1))))
(test "hygiene" 3
      (lambda () (let ((+ *)) (hygiene 2))))

(define-syntax vect1 (syntax-rules ()
                       ((_ #(?a ...)) (?a ...))
                       ((_ (?a ...))  #(?a ...))))
(test-macro "vect1" (1 2 3 4 5)  (vect1 #(1 2 3 4 5)))
(test-macro "vect1" #(1 2 3 4 5) (vect1 (1 2 3 4 5)))

(define-syntax vect2 (syntax-rules ()
                       ((_ #(#(?a ?b) ...))  #(?a ... ?b ...))
                       ((_ #((?a ?b) ...))    (?a ... ?b ...))
                       ((_ (#(?a ?b) ...))    (#(?a ...) #(?b ...)))))

(test-macro "vect2" #(a c e b d f) (vect2 #(#(a b) #(c d) #(e f))))
(test-macro "vect2"  (a c e b d f) (vect2 #((a b) (c d) (e f))))
(test-macro "vect2"  (#(a c e) #(b d f)) (vect2 (#(a b) #(c d) #(e f))))

(define-syntax vect3 (syntax-rules ()
                       ((_ 0 #(?a ... ?b)) ((?a ...) ?b))
                       ((_ 0 ?x) ho)
                       ((_ 1 #(?a ?b ... ?c ?d ?e)) (?a (?b ...) ?c ?d ?e))
                       ((_ 1 ?x) ho)))

(test-macro "vect3" ((a b c d e) f)
            (vect3 0 #(a b c d e f)))
(test-macro "vect3" (() a)
            (vect3 0 #(a)))
(test-macro "vect3" ho
            (vect3 0 #()))
(test-macro "vect3" (a (b c) d e f)
            (vect3 1 #(a b c d e f)))
(test-macro "vect3" (a () b c d)
            (vect3 1 #(a b c d)))
(test-macro "vect3" ho
            (vect3 1 #(a b c)))

(define-syntax dot1 (syntax-rules ()
                      ((_ (?a . ?b)) (?a ?b))
                      ((_ ?loser) #f)))
(test-macro "dot1" (1 2)     (dot1 (1 . 2)))
(test-macro "dot1" (1 (2))   (dot1 (1 2)))
(test-macro "dot1" (1 ())    (dot1 (1)))
(test-macro "dot1" (1 (2 3)) (dot1 (1 2 3)))
(test-macro "dot1" #f        (dot1 ()))

(define-syntax dot2 (syntax-rules ()
                      ((_ ?a . ?b) (?b . ?a))
                      ((_ . ?loser) #f)))
(test-macro "dot2" (2 . 1)     (dot2 1 . 2))
(test-macro "dot2" ((2) . 1)   (dot2 1 2))
(test-macro "dot2" (() . 1)    (dot2 1))
(test-macro "dot2" ((2 3) . 1) (dot2 1 2 3))
(test-macro "dot2" #f          (dot2))

;; pattern to yield (. x) => x
(define-syntax dot3 (syntax-rules ()
                      ((_ (?a ...) ?b) (?a ... . ?b))))
(test-macro "dot3" (1 2 . 3)   (dot3 (1 2) 3))
(test-macro "dot3" 3           (dot3 () 3))

;; see if effective quote introduced by quasiquote properly unwrap
;; syntactic environment.
(define-syntax unwrap1 (syntax-rules ()
                         ((_ x) `(a ,x))))
(test "unwrap1" '(a 3) (lambda () (unwrap1 3))
      (lambda (x y) (and (eq? (car x) (car y)) (eq? (cadr x) (cadr y)))))
(test "unwrap1" '(a 4) (lambda () (let ((a 4)) (unwrap1 a)))
      (lambda (x y) (and (eq? (car x) (car y)) (eq? (cadr x) (cadr y)))))

;; regression check for quasiquote hygienty handling code
(define-syntax qq1 (syntax-rules ()
                     ((_ a) `(,@a))))
(define-syntax qq2 (syntax-rules ()
                     ((_ a) `#(,@a))))

(test "qq1" '()  (lambda () (qq1 '())))
(test "qq2" '#() (lambda () (qq2 '())))

;; R7RS style alternative ellipsis
(test-section "alternative ellipsis")

(define-syntax alt-elli1
  (syntax-rules ooo ()
    [(_ ... ooo) '((... ...) ooo)]))

(test "alt-elli1" '((a a) (b b) (c c)) (lambda () (alt-elli1 a b c)))

(define-syntax alt-elli2
  (syntax-rules ::: ()
    [(_ ... :::) '((... ...) :::)]))

(test "alt-elli2" '((a a) (b b) (c c)) (lambda () (alt-elli2 a b c)))

;; https://srfi-email.schemers.org/srfi-148/msg/6115633
(define-syntax alt-elli3
  (syntax-rules ... (...)
    [(m x y ...) 'ellipsis]
    [(m x ...)   'literal]))

(test "alt-elli3" 'literal (lambda () (alt-elli3 x ...)))

;;----------------------------------------------------------------------
;; cond, taken from R5RS section 7.3

(test-section "recursive expansion")

(define-syntax %cond
  (syntax-rules (else =>)
    ((cond (else result1 result2 ...))
     (begin result1 result2 ...))
    ((cond (test => result))
     (let ((temp test))
       (if temp (result temp))))
    ((cond (test => result) clause1 clause2 ...)
     (let ((temp test))
       (if temp
           (result temp)
           (%cond clause1 clause2 ...))))
    ((cond (test)) test)
    ((cond (test) clause1 clause2 ...)
     (let ((temp test))
       (if temp temp (%cond clause1 clause2 ...))))
    ((cond (test result1 result2 ...))
     (if test (begin result1 result2 ...)))
    ((cond (test result1 result2 ...) clause1 clause2 ...)
     (if test (begin result1 result2 ...) (%cond clause1 clause2 ...)))
    ))

(test-macro "%cond" (begin a) (%cond (else a)))
(test-macro "%cond" (begin a b c) (%cond (else a b c)))
(test-macro "%cond" (let ((temp a)) (if temp (b temp))) (%cond (a => b)))
(test-macro "%cond" (let ((temp a)) (if temp (b temp) (%cond c))) (%cond (a => b) c))
(test-macro "%cond" (let ((temp a)) (if temp (b temp) (%cond c d))) (%cond (a => b) c d))
(test-macro "%cond" (let ((temp a)) (if temp (b temp) (%cond c d e))) (%cond (a => b) c d e))
(test-macro "%cond" a (%cond (a)))
(test-macro "%cond" (let ((temp a)) (if temp temp (%cond b))) (%cond (a) b))
(test-macro "%cond" (let ((temp a)) (if temp temp (%cond b c))) (%cond (a) b c))
(test-macro "%cond" (if a (begin b)) (%cond (a b)))
(test-macro "%cond" (if a (begin b c d)) (%cond (a b c d)))
(test-macro "%cond" (if a (begin b c d) (%cond e f g)) (%cond (a b c d) e f g))

;; test for higiene
(test "%cond" '(if a (begin => b))
      (lambda () (let ((=> #f)) (unident (%macroexpand (%cond (a => b)))))))
(test "%cond" '(if else (begin z))
      (lambda () (let ((else #t)) (unident (%macroexpand (%cond (else z)))))))

;;----------------------------------------------------------------------
;; letrec, taken from R5RS section 7.3
(define-syntax %letrec
  (syntax-rules ()
    ((_ ((var1 init1) ...) body ...)
     (%letrec "generate_temp_names"
              (var1 ...)
              ()
              ((var1 init1) ...)
              body ...))
    ((_ "generate_temp_names" () (temp1 ...) ((var1 init1) ...) body ...)
     (let ((var1 :undefined) ...)
       (let ((temp1 init1) ...)
         (set! var1 temp1) ...
         body ...)))
    ((_ "generate_temp_names" (x y ...) (temp ...) ((var1 init1) ...) body ...)
     (%letrec "generate_temp_names"
              (y ...)
              (newtemp temp ...)
              ((var1 init1) ...)
              body ...))))

;; Note: if you "unident" the expansion result of %letrec, you see a symbol
;; "newtemp" appears repeatedly in the let binding, seemingly expanding
;; into invalid syntax.  Internally, however, those symbols are treated
;; as identifiers with the correct identity, so the expanded code works
;; fine (as tested in the second test).
(test-macro "%letrec"
            (let ((a :undefined)
                  (c :undefined))
              (let ((newtemp b)
                    (newtemp d))
                (set! a newtemp)
                (set! c newtemp)
                e f g))
            (%letrec ((a b) (c d)) e f g))
(test "%letrec" '(1 2 3)
      (lambda () (%letrec ((a 1) (b 2) (c 3)) (list a b c))))

;;----------------------------------------------------------------------
;; do, taken from R5RS section 7.3
(define-syntax %do
  (syntax-rules ()
    ((_ ((var init step ...) ...)
        (test expr ...)
        command ...)
     (letrec
         ((loop
           (lambda (var ...)
             (if test
                 (begin
                   (if #f #f)
                   expr ...)
                 (begin
                   command
                   ...
                   (loop (%do "step" var step ...)
                         ...))))))
       (loop init ...)))
    ((_ "step" x)
     x)
    ((_ "step" x y)
     y)))

(test-macro "%do"
            (letrec ((loop (lambda (x y)
                             (if (>= x 10)
                                 (begin (if #f #f) y)
                                 (begin (loop (%do "step" x (+ x 1))
                                              (%do "step" y (* y 2))))))))
              (loop 0 1))
            (%do ((x 0 (+ x 1))
                  (y 1 (* y 2)))
                 ((>= x 10) y)))
(test "%do" 1024
      (lambda () (%do ((x 0 (+ x 1))
                       (y 1 (* y 2)))
                      ((>= x 10) y))))

(test-macro "%do"
            (letrec ((loop (lambda (y x)
                             (if (>= x 10)
                                 (begin (if #f #f) y)
                                 (begin (set! y (* y 2))
                                        (loop (%do "step" y)
                                              (%do "step" x (+ x 1))))))))
              (loop 1 0))
            (%do ((y 1)
                  (x 0 (+ x 1)))
                 ((>= x 10) y)
                 (set! y (* y 2))))
(test "%do" 1024
      (lambda () (%do ((y 1)
                       (x 0 (+ x 1)))
                      ((>= x 10) y)
                      (set! y (* y 2)))))

;;----------------------------------------------------------------------
;; non-syntax-rule transformers

(test-section "transformers other than syntax-rules")

(define-syntax xif if)
(test "xif" 'ok (lambda () (xif #f 'ng 'ok)))

(define-syntax fi (syntax-rules () [(_ a b c) (xif a c b)]))
(define-syntax xfi fi)
(test "xfi" 'ok (lambda () (xfi #f 'ok 'ng)))

;;----------------------------------------------------------------------
;; local syntactic bindings.

(test-section "local syntactic bindings")

(test "let-syntax"                      ; R5RS 4.3.1
      'now
      (lambda ()
        (let-syntax ((%when (syntax-rules ()
                             ((_ test stmt1 stmt2 ...)
                              (if test (begin stmt1 stmt2 ...))))))
          (let ((if #t))
            (%when if (set! if 'now))
            if))))

(test "let-syntax"                      ; R5RS 4.3.1
      'outer
      (lambda ()
        (let ((x 'outer))
          (let-syntax ((m (syntax-rules () ((m) x))))
            (let ((x 'inner))
              (m))))))

(test "let-syntax (multi)"
      81
      (lambda ()
        (let ((+ *))
          (let-syntax ((a (syntax-rules () ((_ ?x) (+ ?x ?x))))
                       (b (syntax-rules () ((_ ?x) (* ?x ?x)))))
            (let ((* -)
                  (+ /))
              (a (b 3)))))))

(test "let-syntax (nest)"
      19
      (lambda ()
        (let-syntax ((a (syntax-rules () ((_ ?x ...) (+ ?x ...)))))
          (let-syntax ((a (syntax-rules ()
                            ((_ ?x ?y ...) (a ?y ...))
                            ((_) 2))))
            (a 8 9 10)))))

(test "let-syntax (nest)"
      '(-6 11)
      (lambda ()
        (let-syntax ((a (syntax-rules () ((_ ?x) (+ ?x 8))))
                     (b (syntax-rules () ((_ ?x) (- ?x 8)))))
          (let-syntax ((a (syntax-rules () ((_ ?x) (b 2))))
                       (b (syntax-rules () ((_ ?x) (a 3)))))
            (list (a 7) (b 8))))))

(test "letrec-syntax"                   ; R5RS 4.3.1
      7
      (lambda ()
        (letrec-syntax ((%or (syntax-rules ()
                               ((_) #f)
                               ((_ e) e)
                               ((_ e f ...)
                                (let ((temp e))
                                  (if temp temp (%or f ...)))))))
           (let ((x #f)
                 (y 7)
                 (temp 8)
                 (let odd?)
                 (if even?))
             (%or x (let temp) (if y) y)))))

(test "letrec-syntax (nest)"
      2
      (lambda ()
        (letrec-syntax ((a (syntax-rules () ((_ ?x ...) (+ ?x ...)))))
          (letrec-syntax ((a (syntax-rules ()
                               ((_ ?x ?y ...) (a ?y ...))
                               ((_) 2))))
            (a 8 9 10)))))

(test "letrec-syntax (nest)"
      '(9 11)
      (lambda ()
        (letrec-syntax ((a (syntax-rules () ((_ ?x) (+ ?x 8))))
                        (b (syntax-rules () ((_ ?x) (- ?x 8)))))
          (letrec-syntax ((a (syntax-rules ()
                               ((_ ?x)    (b ?x 2))
                               ((_ ?x ?y) (+ ?x ?y))))
                          (b (syntax-rules ()
                               ((_ ?x)    (a ?x 3))
                               ((_ ?x ?y) (+ ?x ?y)))))
            (list (a 7) (b 8))))))

(test "letrec-syntax (recursive)"
      #t
      (lambda ()
        (letrec-syntax ((o? (syntax-rules ()
                              ((o? ()) #f)
                              ((o? (x . xs)) (e? xs))))
                        (e? (syntax-rules ()
                              ((e? ()) #t)
                              ((e? (x . xs)) (o? xs)))))
          (e? '(a a a a)))))

;; shadowing variable binding with syntactic binding
;; it was allowed up to 0.9.10, but no longer.
(test "shadowing" (test-error <error> #/Non-identifier-macro can't appear/)
      (lambda ()
        (eval '(let ((x 0))
                 (let-syntax ((x (syntax-rules () ((_) 1))))
                   (list x)))
              (current-module))))

;; This is from comp.lang.scheme posting by Antti Huima
;; http://groups.google.com/groups?hl=ja&selm=7qpu5ncg2l.fsf%40divergence.tcs.hut.fi
(test "let-syntax (huima)" '(1 3 5 9)
      (lambda ()
        (define the-procedure
          (let-syntax((l(syntax-rules()((l((x(y ...))...)b ...)(let-syntax((x (syntax-rules()y ...))...) b ...)))))(l('(('(a b ...)(lambda a b ...)))`((`(a b c)(if a b c))(`(a)(car a))),((,(a b)(set! a b))(,(a)(cdr a))),@((,@z(call-with-current-continuation z))))'((ls)('((s)('((i) ('((d)('((j)('((c)('((p)('((l)('(()(l l))))'((k)`((pair?,(p))('((c) ,(p(append,(,(p))(d c)))(k k))(c`(p)`(,(p))c))`(p)))))(cons(d)(map d ls))))'((x y c),@'((-)(s x y null? - s)(j x y c)))))'((x y c)('((q)('((f)(cons`(q)(c((f x)x)((f y)y)c)))'((h)`((eq? q h)'((x),(x)) i)))),@'((-)(s x y'((z)(>=`(z)(sqrt(*`(x)`(y)))))- s))))))list)) '((z)z)))'((x y p k l),@'((-)`((p x)(k y)(l y x'((z)`((p z)-(- #f)))k l)))))))))
        (the-procedure '(5 1 9 3))))


(test "let-syntax, rebinding syntax" 'ok
      (lambda ()
        (let-syntax ([xif if] [if when]) (xif #f 'ng 'ok))))

(test "let-syntax, rebinding macro" 'ok
      (lambda ()
        (let-syntax ([if fi]) (if #f 'ok 'ng))))

;; Macro-generating-macro scoping
;; Currently it's not working.
(define-syntax mgm-bar
  (syntax-rules ()
    ((_ . xs) '(bad . xs))))

(define-syntax mgm-foo
  (syntax-rules ()
    ((_ xs)
     (letrec-syntax ((mgm-bar
                      (syntax-rules ()
                        ((_ (%x . %xs) %ys)
                         (mgm-bar %xs (%x . %ys)))
                        ((_ () %ys)
                         '%ys))))
       (mgm-bar xs ())))))

(test "macro-generating-macro scope" '(z y x)
      (lambda () (mgm-foo (x y z))))

;;----------------------------------------------------------------------
;; macro and internal define

(test-section "macro and internal define")

(define-macro (gen-idef-1 x)
  `(define foo ,x))

(test "define foo (legacy)" 3
      (lambda ()
        (gen-idef-1 3)
        foo))
(test "define foo (legacy)" '(3 5)
      (lambda ()
        (let ((foo 5))
          (list (let () (gen-idef-1 3) foo)
                foo))))
(define foo 10)
(test "define foo (legacy)" '(3 10)
      (lambda ()
        (list (let () (gen-idef-1 3) foo) foo)))
(test "define foo (legacy)" '(4 5)
      (lambda ()
        (gen-idef-1 4)
        (define bar 5)
        (list foo bar)))
(test "define foo (legacy)" '(4 5)
      (lambda ()
        (define bar 5)
        (gen-idef-1 4)
        (list foo bar)))

(test "define foo (error)" (test-error)
      (lambda ()
        (eval '(let ()
                 (list 3 4)
                 (gen-idef-1 5)))))
(test "define foo (error)" (test-error)
      (lambda ()
        (eval '(let ()
                 (gen-idef-1 5)))))

(test "define foo (shadow)" 10
      (lambda ()
        (let ((gen-idef-1 -))
          (gen-idef-1 5)
          foo)))

(define-macro (gen-idef-2 x y)
  `(begin (define foo ,x) (define bar ,y)))

(test "define foo, bar (legacy)" '((0 1) 10)
      (lambda ()
        (let ((l (let () (gen-idef-2 0 1) (list foo bar))))
          (list l foo))))
(test "define foo, bar (legacy)" '(-1 -2 20)
      (lambda ()
        (define baz 20)
        (gen-idef-2 -1 -2)
        (list foo bar baz)))
(test "define foo, bar (legacy)" '(-1 -2 20)
      (lambda ()
        (gen-idef-2 -1 -2)
        (define baz 20)
        (list foo bar baz)))
(test "define foo, bar (legacy)" '(3 4 20 -10)
      (lambda ()
        (begin
          (define biz -10)
          (gen-idef-2 3 4)
          (define baz 20))
        (list foo bar baz biz)))
(test "define foo, bar (legacy)" '(3 4 20 -10)
      (lambda ()
        (define biz -10)
        (begin
          (gen-idef-2 3 4)
          (define baz 20)
          (list foo bar baz biz))))
(test "define foo, bar (legacy)" '(3 4 20 -10)
      (lambda ()
        (begin
          (define biz -10))
        (begin
          (gen-idef-2 3 4))
        (define baz 20)
        (list foo bar baz biz)))
(test "define foo, bar (error)" (test-error)
      (lambda ()
        (eval '(let ()
                 (list 3)
                 (gen-idef-2 -1 -2)
                 (list foo bar)))))
(test "define foo, bar (error)" (test-error)
      (lambda ()
        (eval '(let ()
                 (gen-idef-2 -1 -2)))))

(define-syntax gen-idef-3
  (syntax-rules ()
    ((gen-idef-3 x y)
     (begin (define x y)))))

(test "define boo (r5rs)" 3
      (lambda ()
        (gen-idef-3 boo 3)
        boo))
(test "define boo (r5rs)" '(3 10)
      (lambda ()
        (let ((l (let () (gen-idef-3 foo 3) foo)))
          (list l foo))))

(define-syntax gen-idef-4
  (syntax-rules ()
    ((gen-idef-4 x y)
     (begin (define x y) (+ x x)))))

(test "define poo (r5rs)" 6
      (lambda ()
        (gen-idef-4 poo 3)))

(test "define poo (r5rs)" 3
      (lambda ()
        (gen-idef-4 poo 3) poo))

(define-macro (gen-idef-5 o e)
  `(begin
     (define (,o n)
       (if (= n 0) #f (,e (- n 1))))
     (define (,e n)
       (if (= n 0) #t (,o (- n 1))))))

(test "define (legacy, mutually-recursive)" '(#t #f)
      (lambda ()
        (gen-idef-5 ooo? eee?)
        (list (ooo? 5) (eee? 7))))


(define-syntax gen-idef-6
  (syntax-rules ()
    ((gen-idef-6 o e)
     (begin
       (define (o n) (if (= n 0) #f (e (- n 1))))
       (define (e n) (if (= n 0) #t (o (- n 1))))))))

(test "define (r5rs, mutually-recursive)" '(#t #f)
      (lambda ()
        (gen-idef-5 ooo? eee?)
        (list (ooo? 5) (eee? 7))))

;; crazy case when define is redefined
(define-module mac-idef
  (export (rename my-define define))
  (define (my-define . args) args))

(define-module mac-idef.user
  (import mac-idef))

(test "define (redefined)" '(5 2)
      (lambda ()
        (with-module mac-idef.user
          (let ((a 5)) (define a 2)))))

(define-module mac-idef2
  (export (rename my-define define))
  (define-syntax my-define
    (syntax-rules ()
      [(_ var expr) (define (var) expr)])))

(define-module mac-idef2.user
  (import mac-idef2))

(test "define (redefined2)" 5
      (lambda ()
        (with-module mac-idef2.user
          (let ((a 5)) (define x a) (x)))))

(test "internal define-syntax and scope 1" 'inner
      (let ((x 'outer))
        (lambda ()
          (define x 'inner)
          (define-syntax foo
            (syntax-rules ()
              [(_) x]))
          (foo))))

(test "internal define-syntax and scope 2" 'inner
      (let ((x 'outer))
        (lambda ()
          (define-syntax foo
            (syntax-rules ()
              [(_) x]))
          (define x 'inner)
          (foo))))

(test "internal define-syntax and scope 3" '(inner inner)
      (let ((x 'outer))
        (lambda ()
          (define-syntax def
            (syntax-rules ()
              [(_ v) (define v x)]))
          (define x 'inner)
          (def y)
          (list x y))))

(test "internal define-syntax and scope 4" '(inner inner)
      (let ((x 'outer))
        (lambda ()
          (define-syntax def
            (syntax-rules ()
              [(_ v) (define v (lambda () x))]))
          (def y)
          (define x 'inner)
          (list x (y)))))

(test "internal define-syntax and scope 5" '(inner (inner . innermost))
      (let ((x 'outer))
        (lambda ()
          (define-syntax def1
            (syntax-rules ()
              [(_ v) (def2 v x)]))
          (define-syntax def2
            (syntax-rules ()
              [(_ v y) (define v (let ((x 'innermost))
                                   (lambda () (cons y x))))]))
          (def1 z)
          (define x 'inner)
          (list x (z)))))

;;----------------------------------------------------------------------
;; macro defining macros

(test-section "macro defining macros")

(define-syntax mdm-foo1
  (syntax-rules ()
    ((mdm-foo1 x y)
     (define-syntax x
       (syntax-rules ()
         ((x z) (cons z y)))))
    ))

(mdm-foo1 mdm-cons 0)

(test "define-syntax - define-syntax" '(1 . 0)
      (lambda () (mdm-cons 1)))

(define-syntax mdm-foo2
  (syntax-rules ()
    ((mdm-foo2 x y)
     (let-syntax ((x (syntax-rules ()
                       ((x z) (cons z y)))))
       (x 1)))))

(test "define-syntax - let-syntax" '(1 . 0)
      (lambda () (mdm-foo2 cons 0)))

(test "let-syntax - let-syntax" '(4 . 3)
      (lambda ()
        (let-syntax ((mdm-foo3 (syntax-rules ()
                                 ((mdm-foo3 x y body)
                                  (let-syntax ((x (syntax-rules ()
                                                    ((x z) (cons z y)))))
                                    body)))))
          (mdm-foo3 list 3 (list 4)))))

(test "letrec-syntax - let-syntax" 3
      (lambda ()
        (letrec-syntax ((mdm-foo4
                         (syntax-rules ()
                           ((mdm-foo4 () n) n)
                           ((mdm-foo4 (x . xs) n)
                            (let-syntax ((mdm-foo5
                                          (syntax-rules ()
                                            ((mdm-foo5)
                                             (mdm-foo4 xs (+ n 1))))))
                              (mdm-foo5))))))
          (mdm-foo4 (#f #f #f) 0))))

(define-syntax mdm-foo3
  (syntax-rules ()
    ((mdm-foo3 y)
     (letrec-syntax ((o? (syntax-rules ()
                           ((o? ()) #f)
                           ((o? (x . xs)) (e? xs))))
                     (e? (syntax-rules ()
                           ((e? ()) #t)
                           ((e? (x . xs)) (o? xs)))))
       (e? y)))))

(test "define-syntax - letrec-syntax" #t
      (lambda () (mdm-foo3 (a b c d))))

;; Examples from "Two pitfalls in programming nested R5RS macros"
;; by Oleg Kiselyov
;;  http://pobox.com/~oleg/ftp/Scheme/r5rs-macros-pitfalls.txt

(define-syntax mdm-bar-m
  (syntax-rules ()
    ((_ x y)
     (let-syntax
         ((helper
           (syntax-rules ()
             ((_ u) (+ x u)))))
       (helper y)))))

(test "lexical scope" 5
      (lambda () (mdm-bar-m 4 1)))

(define-syntax mdm-bar-m1
  (syntax-rules ()
    ((_ var body)
     (let-syntax
         ((helper
           (syntax-rules ()
             ((_) (lambda (var) body)))))
       (helper)))))

(test "lexical scope" 5
      (lambda () ((mdm-bar-m1 z (+ z 1)) 4)))

(define-syntax mdm-bar-m3
  (syntax-rules ()
    ((_ var body)
     (let-syntax
         ((helper
           (syntax-rules ()
             ((_ vvar bbody) (lambda (vvar) bbody)))))
       (helper var body)))))

(test "passing by parameters" 5
      (lambda () ((mdm-bar-m3 z (+ z 1)) 4)))

;; Macro defining toplevel macros.
(define-syntax defMyQuote
  (syntax-rules ()
    ((_ name)
     (begin
       (define-syntax TEMP
         (syntax-rules ()
           ((_ arg)
            `arg)))
       (define-syntax name
         (syntax-rules ()
           ((_ arg)
            (TEMP arg))))))))

(defMyQuote MyQuote)

(test "macro defining a toplevel macro" '(1 2 3)
      (lambda () (MyQuote (1 2 3))))

;; Macro inserting toplevel identifier
(define-module defFoo-test
  (export defFoo)
  (define-syntax defFoo
    (syntax-rules ()
      [(_ accessor)
       (begin
         (define foo-toplevel 42)
         (define (accessor) foo-toplevel))])))

(import defFoo-test)
(defFoo get-foo)

(test "macro injecting toplevel definition" '(#f #f 42)
      (lambda ()
        (list (module-binding-ref (current-module) 'foo-toplevel #f)
              (module-binding-ref 'defFoo-test 'foo-toplevel #f)
              (get-foo))))

;; recursive reference in macro-defined-macro
;; https://gist.github.com/ktakashi/03ae059f804a723a9589
(define-syntax assocm
  (syntax-rules ()
    ((_ key (alist ...))
     (letrec-syntax ((fooj (syntax-rules (key)
                            ((_ (key . e) res (... ...)) '(key . e))
                            ((_ (a . d) res (... ...)) (fooj res (... ...))))))
       (fooj alist ...)))))

(test "recursive reference in macro-defined-macro" '(c . d)
      (lambda () (assocm c ((a . b) (b . d) (c . d) (d . d)))))

;; literal identifier comparison with renamed identifier
;; https://gist.github.com/ktakashi/fa4ee23da88151536619
(define-module literal-id-test-sub
  (export car))

(define-module literal-id-test
  (use gauche.test)
  (import (literal-id-test-sub :rename ((car car-alias))))

  (define-syntax free-identifier=??
    (syntax-rules ()
      ((_ a b)
       (let-syntax ((foo (syntax-rules (a)
                           ((_ a) #t)
                           ((_ _) #f))))
         (foo b)))))

  (test "literal identifier comparison a a" #t
        (lambda () (free-identifier=?? a a)))
  (test "literal identifier comparison b a" #f
        (lambda () (free-identifier=?? b a)))
  (test "literal identifier comparison car car-alias" #t
        (lambda () (free-identifier=?? car car-alias))))

;; macro defining macro from other module
;; https://github.com/shirok/Gauche/issues/532

(define-module macro-defining-macro-toplevel
  (export x1)
  (define-syntax x1
    (syntax-rules ()
      ((x1 y1)
       (x2 x3 y1))))

  (define-syntax x2
    (syntax-rules ()
      ((x2 x3 y1)
       (begin
         (define-syntax x3
           (syntax-rules ()
             ((x3 x4) x4)))
         (define-syntax y1
           (syntax-rules ()
             ((y1 y2) (x3 y2)))))))))

(define-module macro-defining-macro-toplevel-user
  (use gauche.test)
  (import macro-defining-macro-toplevel)
  (x1 bar)
  ;; without fix, (bar 1) fails with "unbound variable: #<identifier ... x3>"
  (test "macro defining macro in other module" 1
        (lambda () (eval '(bar 1) (current-module)))))

;;----------------------------------------------------------------------
;; identifier comparison

(test-section "identifier comparison")

;; This is EXPERIMENTAL: may be changed in later release.
(define-syntax expand-id-compare (syntax-rules () ((hoge foo ...) (cdr b))))
(test "comparison of identifiers" '(cdr b)
      (lambda () (macroexpand '(expand-id-compare bar) #t)))
(test "comparison of identifiers" (macroexpand '(expand-id-compare bar) #t)
      (lambda () (macroexpand '(expand-id-compare bar) #t)))

;;----------------------------------------------------------------------
;; keyword and extended lambda list

(test-section "keyword inserted by macro")

(define-syntax define-extended-1
  (syntax-rules ()
    [(_ name)
     (define (name a :key (b #f))
       (list a b))]))

(define-extended-1 extended-1)
(test "macro expands to extended lambda list" '(1 2)
      (lambda () (extended-1 1 :b 2)))

(define-syntax define-extended-2
  (syntax-rules ()
    [(_ name)
     (define (name a :key ((:b boo) #f))
       (list a boo))]))
(define-extended-2 extended-2)
(test "macro expands to extended lambda list" '(3 4)
      (lambda () (extended-2 3 :b 4)))

;;----------------------------------------------------------------------
;; common-macros

(test-section "common-macros utilities")

(test "push!" '(1 2 3)
      (lambda ()
        (let ((a '()))
          (push! a 3) (push! a 2) (push! a 1)
          a)))

(test "push!" '(0 1 2 3)
      (lambda ()
        (let ((a (list 0)))
          (push! (cdr a) 3) (push! (cdr a) 2) (push! (cdr a) 1)
          a)))

(test "push!" '#((1 2) (3 . 0))
      (lambda ()
        (let ((a (vector '() 0)))
          (push! (vector-ref a 0) 2)
          (push! (vector-ref a 0) 1)
          (push! (vector-ref a 1) 3)
          a)))

(test "push-unique!" '(3 2 1)
      (lambda ()
        (let ((a '(1)))
          (push-unique! a 1)
          (push-unique! a 2)
          (push-unique! a 3)
          (push-unique! a 2)
          (push-unique! a 1)
          (push-unique! a 3)
          a)))

(test "push-unique!" '#((3 2 1) (3 1 2))
      (lambda ()
        (let ((a (vector '() '())))
          (push-unique! (vector-ref a 0) 1)
          (push-unique! (vector-ref a 0) 2)
          (push-unique! (vector-ref a 0) 3)
          (push-unique! (vector-ref a 0) 2)
          (push-unique! (vector-ref a 0) 1)
          (push-unique! (vector-ref a 0) 3)
          (push-unique! (vector-ref a 1) 2)
          (push-unique! (vector-ref a 1) 1)
          (push-unique! (vector-ref a 1) 3)
          (push-unique! (vector-ref a 1) 1)
          a)))

(test "push-unique!" '("a" "B" "c")
      (lambda ()
        (let ((a '("c")))
          (push-unique! a "B" string-ci=?)
          (push-unique! a "C" string-ci=?)
          (push-unique! a "a" string-ci=?)
          (push-unique! a "b" string-ci=?)
          (push-unique! a "A" string-ci=?)
          a)))

(test "push-unique!" '(("a" "B" "c"))
      (lambda ()
        (let ((a (list '("c"))))
          (push-unique! (car a) "B" string-ci=?)
          (push-unique! (car a) "C" string-ci=?)
          (push-unique! (car a) "a" string-ci=?)
          (push-unique! (car a) "b" string-ci=?)
          (push-unique! (car a) "A" string-ci=?)
          a)))

(test "pop!" '((2 3) . 1)
      (lambda ()
        (let* ((a (list 1 2 3))
               (b (pop! a)))
          (cons a b))))

(test "pop!" '((1 3) . 2)
      (lambda ()
        (let* ((a (list 1 2 3))
               (b (pop! (cdr a))))
          (cons a b))))

(test "pop!" '(#((2)) . 1)
      (lambda ()
        (let* ((a (vector (list 1 2)))
               (b (pop! (vector-ref a 0))))
          (cons a b))))

(test "push!, pop!" '((2 3) (4 1))
      (lambda ()
        (let ((a (list 1 2 3))
              (b (list 4)))
          (push! (cdr b) (pop! a))
          (list a b))))

(test "inc!" 3
      (lambda () (let ((x 2)) (inc! x) x)))
(test "inc!" 4
      (lambda () (let ((x 2)) (inc! x 2) x)))
(test "inc!" '(4 . 1)
      (lambda ()
        (let ((x (cons 3 1)))
          (inc! (car x)) x)))
(test "inc!" '(1 . 1)
      (lambda ()
        (let ((x (cons 3 1)))
          (inc! (car x) -2) x)))
(test "inc!" '((4 . 1) 1)
      (lambda ()
        (let ((x (cons 3 1))
              (y 0))
          (define (zz) (inc! y) car)
          (inc! ((zz) x))
          (list x y))))
(test "dec!" 1
      (lambda () (let ((x 2)) (dec! x) x)))
(test "dec!" 0
      (lambda () (let ((x 2)) (dec! x 2) x)))
(test "dec!" '(2 . 1)
      (lambda ()
        (let ((x (cons 3 1)))
          (dec! (car x)) x)))
(test "dec!" '(5 . 1)
      (lambda ()
        (let ((x (cons 3 1)))
          (dec! (car x) -2) x)))
(test "dec!" '((2 . 1) -1)
      (lambda ()
        (let ((x (cons 3 1))
              (y 0))
          (define (zz) (dec! y) car)
          (dec! ((zz) x))
          (list x y))))

(test "rotate!" '(2 1)
      (lambda ()
        (let ((a 1)
              (b 2))
          (rotate! a b)
          (list a b))))
(test "rotate!" '(2 3 1)
      (lambda ()
        (let ((a 1)
              (b 2)
              (c 3))
          (rotate! a b c)
          (list a b c))))
(test "rotate!" '(2 3 1)
      (lambda ()
        (let ((vals (list 1 2 3)))
          (rotate! (car vals) (cadr vals) (list-ref vals 2))
          vals)))

(let ((x 0) (xx 0) (y 0) (yy 0) (yyy 0) (z 0))
  (define-syntax t-ineq
    (syntax-rules ()
      [(_ expect form)
       (test 'form expect (lambda () form))]))

  ;; Using set! to prevent the compiler does constant folding
  (set! x -0.5)
  (set! x xx)
  (set! y 13.0)
  (set! yy y)
  (set! yyy y)
  (set! z +inf.0)

  (t-ineq #t (ineq x < y < z))
  (t-ineq #f (ineq 0 < x < 1 < y))
  (t-ineq #t (ineq -1 < x < 1 < y))
  (t-ineq #f (ineq x < xx))
  (t-ineq #t (ineq x <= xx))
  (t-ineq #t (ineq x <= xx <= y <= yy <= yyy))
  (t-ineq #f (ineq y < yy < yyy))
  (t-ineq #f (ineq x > y > z))
  (t-ineq #f (ineq x >= y >= yyy))
  (t-ineq #t (ineq z >= y >= yyy))
  (t-ineq #t (ineq x < y = yyy < z))
  )

(test "dotimes" '(0 1 2 3 4 5 6 7 8 9)
      (lambda ()
        (let ((m '()))
          (dotimes (n 10) (push! m n))
          (reverse m))))
(test "dotimes" '(0 1 2 3 4 5 6 7 8 9)
      (lambda ()
        (let ((m '()))
          (dotimes (n 10 (reverse m)) (push! m n)))))
(test "dotimes" '(0 1 2 3 4 5 6 7 8 9)
      (lambda ()
        (let ((m '()))
          (dotimes (n (if (null? m) 10 (error "Boom!")) (reverse m))
                   (push! m n)))))

(test "while" 9
      (lambda ()
        (let ((a 10)
              (b 0))
          (while (positive? (dec! a))
            (inc! b))
          b)))
(test "while" 0
      (lambda ()
        (let ((a -1)
              (b 0))
          (while (positive? (dec! a))
            (inc! b))
          b)))

(test "while =>" 6
      (lambda ()
        (let ((a '(1 2 3 #f))
              (b 0))
          (while (pop! a)
            => val
            (inc! b val))
          b)))

(test "while => guard" 45
      (lambda ()
        (let ((a 10)
              (b 0))
          (while (dec! a)
            positive? => val
            (inc! b a))
          b)))

(test "until" 10
      (lambda ()
        (let ((a 10) (b 0))
          (until (negative? (dec! a))
            (inc! b))
          b)))
(test "until => guard" 45
      (lambda ()
        (let ((a 10) (b 0))
          (until (dec! a)
            negative? => val
            (inc! b a))
          b)))

(test "values-ref" 3
      (lambda ()
        (values-ref (quotient&remainder 10 3) 0)))
(test "values-ref" 1
      (lambda ()
        (values-ref (quotient&remainder 10 3) 1)))
(test "values-ref" 'e
      (lambda ()
        (values-ref (values 'a 'b 'c 'd 'e) 4)))
(test "values-ref" '(d b)
      (lambda ()
        (receive r
            (values-ref (values 'a 'b 'c 'd 'e) 3 1)
          r)))
(test "values-ref" '(d a b)
      (lambda ()
        (receive r
            (values-ref (values 'a 'b 'c 'd 'e) 3 0 1)
          r)))
(test "values-ref" '(e d c b a)
      (lambda ()
        (receive r
            (values-ref (values 'a 'b 'c 'd 'e) 4 3 2 1 0)
          r)))

(test "values->list" '(3 1)
      (lambda () (values->list (quotient&remainder 10 3))))
(test "values->list" '(1)
      (lambda () (values->list 1)))
(test "values->list" '()
      (lambda () (values->list (values))))

(test "let1" '(2 2 2)
      (lambda () (let1 x (+ 1 1) (list x x x))))
(test "let1" '(2 4)
      (lambda () (let1 x (+ 1 1) (list x (let1 x (+ x x) x)))))

(test "rlet1" 1 (lambda () (rlet1 x (/ 2 2) (+ x x))))

(test "if-let1" 4
      (lambda () (if-let1 it (+ 1 1) (* it 2))))
(test "if-let1" 'bar
      (lambda () (if-let1 it (memq 'a '(b c d)) 'boo 'bar)))

(test "let-values" '(2 1 1 (2) (2 1))
      (lambda () (let ([a 1] [b 2])
                   (let-values ([(a b) (values b a)]
                                [(c . d) (values a b)]
                                [e (values b a)])
                     (list a b c d e)))))

(test "let*-values" '(2 1 2 (1) (1 2))
      (lambda () (let ([a 1] [b 2])
                   (let*-values ([(a b) (values b a)]
                                 [(c . d) (values a b)]
                                 [e (values b a)])
                     (list a b c d e)))))

(test "ecase" 'b
      (lambda () (ecase 3 ((1) 'a) ((2 3) 'b) ((4) 'c))))
(test "ecase" (test-error)
      (lambda () (ecase 5 ((1) 'a) ((2 3) 'b) ((4) 'c))))
(test "ecase" 'd
      (lambda () (ecase 5 ((1) 'a) ((2 3) 'b) ((4) 'c) (else 'd))))

(test "$" '(0 1)
      (lambda () ($ list 0 1)))
(test "$" '(0 1 (2 3 (4 5 (6 7))))
      (lambda () ($ list 0 1 $ list 2 3 $ list 4 5 $ list 6 7)))
(test "$ - $*" '(0 1 (2 3 4 5 6 7))
      (lambda () ($ list 0 1 $ list 2 3 $* list 4 5 $* list 6 7)))
(test "$ - $*" '(0 1 2 3 (4 5 6 7))
      (lambda () ($ list 0 1 $* list 2 3 $ list 4 5 $* list 6 7)))
(test "$ - $*" '(0 1 2 3 4 5 (6 7))
      (lambda () ($ list 0 1 $* list 2 3 $* list 4 5 $ list 6 7)))
(test "$ - partial" '(0 1 (2 3 (4 5 a)))
      (lambda () (($ list 0 1 $ list 2 3 $ list 4 5 $) 'a)))
(test "$ - $* - partial" '(0 1 2 3 4 5 a)
      (lambda () (($ list 0 1 $* list 2 3 $* list 4 5 $) 'a)))
(test "$ - $* - partial" '(0 1 (2 3 (4 5 a b)))
      (lambda () (($ list 0 1 $ list 2 3 $ list 4 5 $*) 'a 'b)))

(test "$ - hygienty" `(0 1 a ,list 2 3 b ,list 4 5)
      (lambda ()
        (let-syntax ([$$ (syntax-rules ()
                           [($$ . xs) ($ . xs)])])
          (let ([$ 'a] [$* 'b])
            ($$ list 0 1 $ list 2 3 $* list 4 5)))))

(test* "cond-list" '() (cond-list))
(test* "cond-list" '(a) (cond-list ('a)))
(test* "cond-list" '(a) (cond-list (#t 'a) (#f 'b)))
(test* "cond-list" '(b) (cond-list (#f 'a) (#t 'b)))
(test* "cond-list" '(a b d) (cond-list (#t 'a) (#t 'b) (#f 'c) (#t 'd)))
(test* "cond-list" '((b)) (cond-list (#f 'a) ('b => list)))
(test* "cond-list" '(a b c d x)
       (cond-list (#t @ '(a b)) (#t @ '(c d)) (#f @ '(e f))
                  ('x => @ list)))

;;----------------------------------------------------------------------
;; macro-expand

(test-section "macroexpand")

(define-macro (foo x)   `(bar ,x ,x))
(define-macro (bar x y) `(list ,x ,x ,y ,y))

(test "macroexpand" '(list 1 1 1 1)
      (lambda () (macroexpand '(foo 1))))
(test "macroexpand-1" '(bar 1 1)
      (lambda () (macroexpand-1 '(foo 1))))

;;----------------------------------------------------------------------
;; not allowing first-class macro

(test-section "failure cases")

(define-macro (bad-if a b c) `(,if ,a ,b ,c))
(test "reject first-class syntax usage" (test-error)
      (lambda () (bad-if #t 'a 'b)))

(define-macro (bad-fi a b c) `(,fi ,a ,b ,c))
(test "reject first-class macro usage" (test-error)
      (lambda () (bad-fi #t 'a 'b)))

;;----------------------------------------------------------------------
;; compiler macros

(test-section "define-hybrid-syntax")

(define-hybrid-syntax cpm
  (lambda (a b) (+ a b))
  (er-macro-transformer
   (lambda (f r c) `(,(r '*) ,(cadr f) ,(caddr f)))))
(test "compiler macro" '(6 5 6)
      (lambda ()
        (list (cpm 2 3)
              (apply cpm '(2 3))
              (let ((* -)) (cpm 2 3)))))

;;----------------------------------------------------------------------
;; syntax error

(test-section "syntax-error")

(define-syntax test-syntax-error
  (syntax-rules ()
    [(_ a) 'ok]
    [(_ a b) (syntax-errorf "bad {~a ~a}" a b)]
    [(_ x ...) (syntax-error "bad number of arguments" x ...)]))

;; NB: These tests depends on the fact that the compile "wraps"
;; the error by <compile-error-mixin> in order.  If the compiler changes
;; the error handling, adjust the tests accordingly.
;; Our purpose here is to make sure syntax-error preserves the offending macro
;; call (test-syntax-error ...).
(test "syntax-error"
      '("bad number of arguments x y z"
        (test-syntax-error x y z)
        (list (test-syntax-error x y z)))
      (lambda ()
        (guard [e (else (let1 xs (filter <compile-error-mixin>
                                         (slot-ref e '%conditions))
                          (cons (condition-message e e)
                                (map (lambda (x) (slot-ref x 'expr)) xs))))]
          (eval '(list (test-syntax-error x y z))
                (interaction-environment)))))
(test "syntax-errorf"
      '("bad {x y}"
        (test-syntax-error x y)
        (list (test-syntax-error x y)))
      (lambda ()
        (guard [e (else (let1 xs (filter <compile-error-mixin>
                                         (slot-ref e '%conditions))
                          (cons (condition-message e e)
                                (map (lambda (x) (slot-ref x 'expr)) xs))))]
          (eval '(list (test-syntax-error x y))
                (interaction-environment)))))

;;----------------------------------------------------------------------
;; 'compare-ellipsis-1' test should output the following error.
;;
;; *** ERROR: in definition of macro mac-sub1:
;; template's ellipsis nesting is deeper than pattern's:
;; (#<identifier user#list.2d80660> #<identifier user#x.2d80690>
;;  #<identifier user#ooo.2d806f0>)
;;
;; 'compare-ellipsis-2' test should output the following error.
;;
;; *** ERROR: in definition of macro mac-sub1:
;; template's ellipsis nesting is deeper than pattern's:
;; (#<identifier user#list.2969870> #<identifier user#x.29698a0>
;;  #<identifier user#ooo.2969900>)

(test-section "compare ellipsis")

(define-syntax ell-test
  (syntax-rules (ooo)
    ((_ zzz)
     (let-syntax
         ((mac-sub1
           (syntax-rules ooo ()
             ((_ x zzz)
              (list x ooo)))))
       (mac-sub1 1 2 3)))))

(test* "compare-ellipsis-1"
       (test-error <error> #/^in definition of macro/)
       (eval
        '(ell-test ooo)
        (interaction-environment)))

(test* "compare-ellipsis-2"
       (test-error <error> #/^in definition of macro/)
       (eval
        '(let ((ooo 'yyy)) (ell-test ooo))
        (interaction-environment)))

;;----------------------------------------------------------------------
;; 'compare-literals-2' test should output the following error.
;;
;; *** ERROR: malformed #<identifier user#lit-test-2.29d4060>:
;; (#<identifier user#lit-test-2.29d4060> #<identifier user#temp.29d40c0>)
;; While compiling: (lit-test-2 temp 1)

(test-section "compare literals")

(define-syntax lit-test-1
  (syntax-rules (temp)
    ((_ temp x)
     (lit-test-1 temp))
    ((_ temp)
     'passed)))

(test* "compare-literals-1" 'passed (lit-test-1 temp 1))

(define-syntax lit-test-2
  (syntax-rules (temp)
    ((_ temp x)
     (let ((temp 100))
       (lit-test-2 temp)))
    ((_ temp)
     'failed)))

(test* "compare-literals-2"
       (test-error <error> #/^malformed/)
       (eval '(lit-test-2 temp 1) (interaction-environment)))

;;----------------------------------------------------------------------
;; 'generate-underbar-1' inserts global underbar into the macro output.
;; It shouldn't be regarded as a pattern variable, so the underbar in
;; the template refers to the global binding of '_'.

(test-section "generate underbar")

(define-syntax gen-underbar
  (syntax-rules (_)
    ((gen-underbar)
     (let-syntax
         ((mac-sub1
           (syntax-rules ()
             ((mac-sub1 _)
              _))))
       (mac-sub1 'failed)))))

(test* "generate-underbar-1" _
       (gen-underbar))

;;----------------------------------------------------------------------
;; 'pattern-variables-1' test should output the following error.
;;
;; *** ERROR: too many pattern variables in the macro definition of pat-vars
;; While compiling: (syntax-rules () ((_ (z1 (x1 x2 x3 x4 x5 x6 x7 x8 x9 x10
;; x11 x12 x13 x14 x15 x16 x17 x ...
;; While compiling: (define-syntax pat-vars (syntax-rules () ((_ (z1 (x1 x2 x3
;; x4 x5 x6 x7 x8 x9 x10 x11 x ...

(test-section "pattern variables check")

(test* "pattern-variables-1"
       (test-error <error> #/^Too many pattern variables/)
       (eval
        '(define-syntax pat-vars
           (syntax-rules ()
             ((_ (z1 (x1 x2 x3 x4 x5 x6 x7 x8 x9 x10
                      x11 x12 x13 x14 x15 x16 x17 x18 x19 x20
                      x21 x22 x23 x24 x25 x26 x27 x28 x29 x30
                      x31 x32 x33 x34 x35 x36 x37 x38 x39 x40
                      x41 x42 x43 x44 x45 x46 x47 x48 x49 x50
                      x51 x52 x53 x54 x55 x56 x57 x58 x59 x60
                      x61 x62 x63 x64 x65 x66 x67 x68 x69 x70
                      x71 x72 x73 x74 x75 x76 x77 x78 x79 x80
                      x81 x82 x83 x84 x85 x86 x87 x88 x89 x90
                      x91 x92 x93 x94 x95 x96 x97 x98 x99 x100
                      x101 x102 x103 x104 x105 x106 x107 x108 x109 x110
                      x111 x112 x113 x114 x115 x116 x117 x118 x119 x120
                      x121 x122 x123 x124 x125 x126 x127 x128 x129 x130
                      x131 x132 x133 x134 x135 x136 x137 x138 x139 x140
                      x141 x142 x143 x144 x145 x146 x147 x148 x149 x150
                      x151 x152 x153 x154 x155 x156 x157 x158 x159 x160
                      x161 x162 x163 x164 x165 x166 x167 x168 x169 x170
                      x171 x172 x173 x174 x175 x176 x177 x178 x179 x180
                      x181 x182 x183 x184 x185 x186 x187 x188 x189 x190
                      x191 x192 x193 x194 x195 x196 x197 x198 x199 x200
                      x201 x202 x203 x204 x205 x206 x207 x208 x209 x210
                      x211 x212 x213 x214 x215 x216 x217 x218 x219 x220
                      x221 x222 x223 x224 x225 x226 x227 x228 x229 x230
                      x231 x232 x233 x234 x235 x236 x237 x238 x239 x240
                      x241 x242 x243 x244 x245 x246 x247 x248 x249 x250
                      x251 x252 x253 x254 x255 x256)))
              (print z1 " " x255 " " x256))))
        (interaction-environment)))

(test* "pattern-variables-2"
       (test-error <error> #/^Pattern levels too deeply nested/)
       (let ()
         (define (build-deep-nested-pattern n f)
           (if (= n 0)
             `(define-syntax pat-vars
                (syntax-rules ()
                  ((_ ,f)
                   (quote ,f))))
             (build-deep-nested-pattern (- n 1) `(,f ...))))
         (eval
          (build-deep-nested-pattern 256 'x)
          (interaction-environment))))

;;----------------------------------------------------------------------
;; let-keyword* hygienic expansion
;;

(test-section "hygienic extened-lambda expansion")
(define-module let-keyword-hygiene-def
  (use gauche.base)
  (use util.match)
  (export klambda)
  (extend scheme)
  (define-syntax klambda
    (er-macro-transformer
     (^[f r c]
       (match f
         [(_ formals&keys . body)
          (quasirename r
            `(lambda (,@(drop-right formals&keys 1)
                      ,(make-keyword 'key)
                      ,@(map (^s `(,s #f)) (last formals&keys)))
               ,@body))])))))

(define-module let-keyword-hygeiene-use
  (import let-keyword-hygiene-def)
  (import gauche.keyword)
  (export call-klambda)
  (extend scheme)
  (define (call-klambda a b c d)
    ((klambda (a b (x y)) (list a b x y))
     a b :x c :y d)))

(test* "hygienic let-keyword expansion" '(1 2 3 4)
       ((with-module let-keyword-hygeiene-use call-klambda) 1 2 3 4))

;; Cf. http://chaton.practical-scheme.net/gauche/a/2020/11/05#entry-5fa3ba50-dc7d3
(define-syntax let-keywords-hygiene-test-1-inner
  (er-macro-transformer
   (^[f r c]
     (let-keywords (cdr f) ([a 1]
                            [b 2])
       (quasirename r `(+ ,a ,b))))))
(define-syntax let-keywords-hygiene-test-1-outer
  (syntax-rules ()
    [(_ x) (let-keywords-hygiene-test-1-inner :b x)]))

(test* "hygienic let-keyword match" 10
       (let-keywords-hygiene-test-1-outer 9))


;;----------------------------------------------------------------------
;; SRFI-147 begin
;; (not yest supported)

'(test-section "SRFI-147 begin")

'(test "SRFI-147 begin (internal) 1"
      '(yes no)
      (lambda ()
        (define-syntax foo
          (begin (define-syntax bar if)
                 (syntax-rules ()
                   [(_ x y z) (bar z x y)])))
        (list (foo 'yes 'no (zero? 0))
              (foo 'yes 'no (zero? 1)))))

'(test "SRFI-147 begin (internal) 2"
      11
      (lambda ()
        (let-syntax ([foo (syntax-rules ()
                            [(_ a) (begin (define x (* a 2))
                                          (syntax-rules ()
                                            [(_ b) (+ b x)]))])])
          (define-syntax bar (foo 3))
          (bar 5))))

(test-end)
