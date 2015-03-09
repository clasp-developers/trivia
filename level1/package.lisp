;;; level1 implementation

(defpackage :trivia.level1
  (:export :match1* :match1 :or1 :guard1 :variables
           :*or-pattern-allow-unshared-variables*
           :or1-pattern-inconsistency
           :guard1-pattern-nonlinear
           :conflicts :pattern :repair-pattern
           :correct-pattern
           :preprocess-symopts))

(defpackage :trivia.level1.impl
  (:use :cl
        :alexandria
        :trivia.level0
        :trivia.level1))

(in-package :trivia.level1.impl)

;;; API

(defmacro match1* (whats &body clauses)
  "based on match1"
  (assert (listp whats))
  (let* ((args (mapcar (gensym* "ARG") whats))
         (bindings (mapcar #'list args whats))
         (clauses
          (mapcar (lambda (clause)
                    (with-gensyms (it) ;; peudo arg
                      (ematch0 clause
                        ((list* patterns body)
                         (list* `(guard1 ,it t ,@(mappend #'list args patterns))
                                body)))))
                  clauses)))
    `(let ,bindings
       (declare (ignorable ,@args))
       (match1 t ,@clauses))))

(defmacro match1 (what &body clauses)
  (once-only (what)
    (%match what clauses)))

;;; syntax error

(define-condition or1-pattern-inconsistency (error)
  ((pattern :initarg :pattern :accessor pattern)
   (conflicts :initarg :conflicts :accessor conflicts))
  (:report (lambda (c s)
             (format s "~< subpatterns of ~:_ ~a ~:_ binds different set of variables: ~:_ ~a, ~:_ ~a ~:>"
                     (list (pattern c)
                           (first (conflicts c))
                           (second (conflicts c)))))))

(define-condition guard1-pattern-nonlinear (error)
  ((pattern :initarg :pattern :accessor pattern)
   (conflicts :initarg :conflicts :accessor conflicts))
  (:report (lambda (c s)
             (format s "~< guard1 pattern ~:_ ~a ~:_ rebinds a variable ~a. current context: ~:_ ~a ~:>"
                     (list (pattern c)
                           (apply #'intersection (conflicts c))
                           (first (conflicts c)))))))

;;; outer construct

(defun gensym* (name)
  (lambda (x)
    (declare (ignore x))
    (gensym name)))


(defun %match (arg clauses)
  `(block nil
     ,@(match-clauses arg clauses)))

(defun match-clauses (arg clauses)
  (mapcar
   (lambda-ematch0
     ((list* pattern body)
      (match-clause arg
                    (correct-pattern pattern)
                    `(return (locally ,@body)))))
   clauses))

;;; pattern syntax validation

(defvar *lexvars* nil)  ;; list of symbols bound in the context

(defun %correct-more-patterns (more)
  (ematch0 more
    (nil nil)
    ((list* gen sub more)
     (let ((newsub (correct-pattern sub)))
       (list* gen newsub
              (let ((*lexvars* (append (variables newsub) *lexvars*)))
                (%correct-more-patterns more)))))))

(defvar *or-pattern-allow-unshared-variables* t)

(defun union* (&optional x y) (union x y))

(defun correct-pattern (pattern)
  (ematch0 pattern
    ((list* 'guard1 symbol test more-patterns)
     (restart-case
         (progn
           (check-guard1 symbol pattern)
           (let ((*lexvars* (cons symbol *lexvars*)))
             (list* 'guard1 symbol test
                    (%correct-more-patterns more-patterns))))
       (repair-pattern (pattern)
         (correct-pattern pattern))))
    ((list* 'or1 subpatterns)
     (let ((subpatterns (mapcar #'correct-pattern subpatterns)))
       (let ((all-vars (reduce #'union* subpatterns :key #'variables)))
         `(or1 ,@(mapcar
                  (lambda (sp)
                    (let* ((vars (variables sp))
                           (missing (set-difference all-vars vars)))
                      (if *or-pattern-allow-unshared-variables*
                          (bind-missing-vars-with-nil sp missing)
                          (restart-case
                              (progn (assert (null missing)
                                             nil
                                             'or1-pattern-inconsistency
                                             :pattern pattern
                                             :conflicts (list all-vars vars))
                                     sp)
                            (repair-pattern (sp) sp)))))
                  subpatterns)))))))

(defun bind-missing-vars-with-nil (pattern missing)
  (ematch0 missing
    ((list) pattern)
    ((list* var rest)
     (bind-missing-vars-with-nil
      (with-gensyms (it)
        `(guard1 ,it t
                 nil (guard1 ,var t)
                 ,it ,pattern))
      rest))))


(defun check-guard1 (sym pattern)
  (assert (symbolp sym)
          nil
          "guard1 pattern accepts symbol only !
    --> (guard1 symbol test-form {generator subpattern}*)
    symbol: ~a" sym)
  (assert (not (member sym *lexvars*))
          nil
          'guard1-pattern-nonlinear
          :pattern pattern
          :conflicts `((,sym) ,*lexvars*)))

;;; matching form generation

(defun match-clause (arg pattern body)
  (ematch0 pattern
    ((list* 'guard1 symbol test-form more-patterns)
     (let ((*lexvars* (cons symbol *lexvars*)))
       `(let ((,symbol ,arg))
          (declare (ignorable ,symbol))
          (when ,test-form
            ,(destructure-guard1-subpatterns more-patterns body)))))
    ((list* 'or1 subpatterns)
     (let* ((vars (variables pattern)))
       (with-gensyms (fn)
         `(flet ((,fn ,vars
                   (declare (ignorable ,@vars))
                   ;; ,@(when vars `((declare (ignorable ,@vars))))
                   ,body))
            (declare (dynamic-extent (function ,fn)))
            ;; we do not want to mess up the looking of expansion
            ;; with symbol-macrolet
            ,@(mapcar (lambda (pattern)
                        (match-clause arg pattern `(,fn ,@vars)))
                      subpatterns)))))))

(defun destructure-guard1-subpatterns (more-patterns body)
  (ematch0 more-patterns
    (nil body)
    ((list* generator subpattern more-patterns)
     (with-gensyms (field)
       `(let ((,field ,generator))
          (declare (ignorable ,field))
          ,(match-clause field
                         subpattern
                         (let ((*lexvars* (append (variables subpattern)
                                                  *lexvars*)))
                           (destructure-guard1-subpatterns more-patterns body))))))))

;;; utility: variable-list

(defun set-equal-or-error (&optional seq1 seq2)
  (if (set-equal seq1 seq2)
      seq1
      (error "~a and ~a differs! this should have been fixed by correct-pattern, why!!??"
             seq1 seq2)))

(defun variables (pattern &optional *lexvars*)
  (%variables (correct-pattern pattern)))

(defun %variables (pattern)
  "given a pattern, traverse the matching tree and returns a list of variables bounded by guard1 pattern.
gensym'd anonymous symbols are not accounted i.e. when symbol-package is non-nil."
  (ematch0 pattern
    ((list* 'guard1 symbol _ more-patterns)
     (if (symbol-package symbol)
         ;; consider the explicitly named symbols only
         (cons symbol (%variables-more-patterns more-patterns))
         (%variables-more-patterns more-patterns)))
    ((list* 'or1 subpatterns)
     (reduce #'set-equal-or-error
             (mapcar #'%variables subpatterns)))))

(defun %variables-more-patterns (more-patterns)
  (ematch0 more-patterns
    (nil nil)
    ((list* _ subpattern more-patterns)
     (append (%variables subpattern)
             (%variables-more-patterns more-patterns)))))

;; (variables `(guard1 x t (car x) (guard1 y t)))

