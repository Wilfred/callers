;;; refs.el --- find callers of elisp functions or macros

;; Copyright (C) 2016  

;; Author: Wilfred Hughes <me@wilfred.me.uk>
;; Version: 0.1
;; Keywords: lisp
;; Package-Requires: ((dash "2.12.0") (f "0.18.2") (ht "2.1") (list-utils "0.4.4") (loop "2.1") (shut-up "0.3.2"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A package for finding callers of elisp functions or macros. Really
;; useful for finding examples.

;;; Code:

(require 'list-utils)
(require 'dash)
(require 'f)
(require 'ht)
(require 'loop)
(require 'shut-up)
(eval-when-compile (require 'cl-lib))

(defsubst refs--start-pos (end-pos)
  "Find the start position of form ending at END-FORM
in the current buffer."
  (scan-sexps end-pos -1))

(defun refs--sexp-positions (buffer start-pos end-pos)
  "Return a list of start and end positions of all the sexps
between START-POS and END-POS (excluding ends) in BUFFER.

Not recursive, so we don't consider subelements of nested sexps."
  (let ((positions nil)
        (current-pos (1+ start-pos)))
    (with-current-buffer buffer
      (condition-case _err
          ;; Loop until we can't read any more.
          (loop-while t
            (let* ((sexp-end-pos (let ((parse-sexp-ignore-comments t))
                                   (scan-sexps current-pos 1)))
                   (sexp-start-pos (refs--start-pos sexp-end-pos)))
              (if (< sexp-end-pos end-pos)
                  ;; This sexp is inside the range requested.
                  (progn
                    (push (list sexp-start-pos sexp-end-pos) positions)
                    (setq current-pos sexp-end-pos))
                ;; Otherwise, we've reached end the of range.
                (loop-break))))
        ;; Terminate when we see "Containing expression ends prematurely"
        (scan-error (nreverse positions))))))

(defun refs--read-buffer-form ()
  "Read a form from the current buffer, starting at point.
Returns a list (form start-pos end-pos symbol-positions).

Positions are 1-indexed, consistent with `point'."
  (let* ((read-with-symbol-positions t)
         (form (read (current-buffer)))
         (end-pos (point))
         (start-pos (refs--start-pos end-pos)))
    (list form start-pos end-pos read-symbol-positions-list)))

(defvar refs--path nil
  "A buffer-local variable used by `refs--contents-buffer'.
Internal implementation detail.")

(defun refs--read-all-buffer-forms (buffer)
  "Read all the forms in BUFFER, along with their positions."
  (with-current-buffer buffer
    (goto-char (point-min))
    (let ((forms nil))
      (condition-case err
          (while t
            (push (refs--read-buffer-form) forms))
        (error
         (if (or (equal (car err) 'end-of-file)
                 ;; TODO: this shouldn't occur in valid elisp files,
                 ;; but it's happening in helm-utils.el.
                 (equal (car err) 'scan-error))
             ;; Reached end of file, we're done.
             (nreverse forms)
           ;; Some unexpected error, propagate.
           (error "Unexpected error whilst reading %s position %s: %s"
                  (f-abbrev refs--path) (point) err)))))))

(defun refs--walk (buffer form start-pos end-pos match-p &optional path)
  "Walk FORM, a nested list, and return a list of subforms (with
their positions) where MATCH-P returns t.

MATCH-P is called with two arguments:
\(CURRENT-FORM PATH INDEX).

PATH is the first element of all the enclosing forms of
CURRENT-FORM, innermost first, along with the index of the
current form.

For example if we are looking at h in (e f (g h)), PATH takes the
value ((g . 1) (e . 2)).

START-POS and END-POS should be the position of FORM within BUFFER."
  (if (funcall match-p form path)
      ;; If this form matches, just return it, along with the position.
      (list (list form start-pos end-pos))
    ;; Otherwise, see if we should recurse.
    (let ((matches nil)
          ;; Find the positions of the subforms.
          (subforms-positions (refs--sexp-positions buffer start-pos end-pos)))
      ;; For each subform, get its position, and recurse.
      (--each (-zip form subforms-positions)
        (-let [(subform . pos) it]
          ;; TODO: should we allow atoms?
          ;; TODO: add tests for improper lists
          (when (and (consp subform) (not (list-utils-improper-p subform)))
            (-let* (((subform-start subform-end) pos)
                    (subform-matches
                     (refs--walk
                      buffer subform
                      subform-start subform-end
                      match-p
                      (cons (cons (car form) it-index) path))))
              (when subform-matches
                (push subform-matches matches))))))

      ;; Concat the results from all the subforms.
      (apply #'append (nreverse matches)))))

;; TODO: Handle sharp-quoted function references.
(defun refs--call-match-p (symbol)
  "Return a matcher function that looks for SYMBOL in a form."
  (lambda (form path)
    (cond
     ;; Ignore (defun _ (SYMBOL ...) ...)
     ((equal (car path) '(defun . 2))
      nil)
     ;; Ignore (let (SYMBOL ...) ...)
     ;; and (let* (SYMBOL ...) ...)
     ((or
       (equal (car path) '(let . 1))
       (equal (car path) '(let* . 1)))
      nil)
     ;; (SYMBOL ...)
     ((eq (car form) symbol)
      t)
     ;; (funcall 'SYMBOL ...)
     ((and (eq (car form) 'funcall)
           (equal `',symbol (cl-second form)))
      t)
     ;; (apply 'SYMBOL ...)
     ((and (eq (car form) 'apply)
           (equal `',symbol (cl-second form)))
      t))))

(defun refs--find-calls (buffer symbol)
  "Read all the forms in BUFFER, and return a list of all calls to SYMBOL,
along with their positions.

If FORMS-WITH-POSITIONS contain any calls to SYMBOL, return those
subforms, along with their positions."
  (-non-nil
   (--mapcat
    (-let [(form start-pos end-pos symbol-positions) it]
      ;; Optimisation: don't bother walking a form if contains no
      ;; references to the form we're looking for.
      (when (assoc symbol symbol-positions)
        (refs--walk buffer form start-pos end-pos
                    (refs--call-match-p symbol))))
    (refs--read-all-buffer-forms buffer))))

(defun refs--filter-obarray (pred)
  "Return a list of all the items in `obarray' where PRED returns t."
  (let (symbols)
    (mapatoms (lambda (symbol)
                (when (and (funcall pred symbol)
                           (not (equal (symbol-name symbol) "")))
                  (push symbol symbols))))
    symbols))

(defun refs--macros ()
  "Return a list of all symbols that are macros."
  (let (symbols)
    (mapatoms (lambda (symbol)
                (when (macrop symbol)
                  (push symbol symbols))))
    symbols))

(defun refs--loaded-files ()
  "Return a list of all files that have been loaded in Emacs.
Where the file was a .elc, return the path to the .el file instead."
  (let ((elc-paths (-map #'-first-item load-history)))
    (-non-nil
     (--map
      (let ((el-name (format "%s.el" (f-no-ext it)))
            (el-gz-name (format "%s.el.gz" (f-no-ext it))))
        (cond ((f-exists? el-name) el-name)
              ((f-exists? el-gz-name) el-gz-name)
              ;; Ignore files where we can't find a .el file.
              (t nil)))
      elc-paths))))

(defun refs--contents-buffer (path)
  "Read PATH into a disposable buffer, and return it.
Works around the fact that Emacs won't allow multiple buffers
visiting the same file."
  (let ((fresh-buffer (generate-new-buffer (format "refs-%s" path))))
    (with-current-buffer fresh-buffer
      (setq-local refs--path path)
      (shut-up (insert-file-contents path))
      ;; We don't enable emacs-lisp-mode because it slows down this
      ;; function significantly. We just need the syntax table for
      ;; scan-sexps to do the right thing with comments.
      (set-syntax-table emacs-lisp-mode-syntax-table))
    fresh-buffer))

(defvar refs--highlighting-buffer
  nil
  "A temporary buffer used for highlighting.
Since `refs--syntax-highlight' is a hot function, we
don't want to create lots of temporary buffers.")

(defun refs--syntax-highlight (str)
  "Apply font-lock properties to a string STR of Emacs lisp code."
  ;; Ensure we have a highlighting buffer to work with.
  (unless refs--highlighting-buffer
    (setq refs--highlighting-buffer
          (generate-new-buffer " *refs-highlighting*"))
    (with-current-buffer refs--highlighting-buffer
      (delay-mode-hooks (emacs-lisp-mode))))
  
  (with-current-buffer refs--highlighting-buffer
    (erase-buffer)
    (insert str)
    (if (fboundp 'font-lock-ensure)
        (font-lock-ensure)
      (with-no-warnings
        (font-lock-fontify-buffer)))
    (buffer-string)))

(defun refs--unindent-rigidly (string)
  "Given an indented STRING, unindent rigidly until
at least one line has no indent.

Replaces tabs with spaces as a side effect."
  (let* ((lines (s-lines (s-replace "\t" (s-repeat tab-width " ") string)))
         (indents (--map (car (s-match (rx bos (+ whitespace)) it))
                         lines))
         (space-indents (--map (s-replace "\t" (s-repeat tab-width " ") (or it ""))
                               indents))
         (min-indent (-min (--map (length it) space-indents)))
         (unindented-lines (--map (substring it min-indent) lines)))
    (s-join "\n" unindented-lines)))

;; TODO: rename to :-extract-snippet.
(defun refs--containing-lines (buffer start-pos end-pos)
  "Return a string, all the lines in BUFFER that are between
START-POS and END-POS (inclusive).

For the characters that are between START-POS and END-POS,
propertize them."
  (let (expanded-start-pos expanded-end-pos section)
    (with-current-buffer buffer
      ;; Expand START-POS and END-POS to line boundaries.
      (goto-char start-pos)
      (beginning-of-line)
      (setq expanded-start-pos (point))
      (goto-char end-pos)
      (end-of-line)
      (setq expanded-end-pos (point))

      ;; Extract the rest of the line before and after the section we're interested in.
      (let* ((before-match (buffer-substring expanded-start-pos start-pos))
             (after-match (buffer-substring end-pos expanded-end-pos)))
        ;; Concat the extra text with the actual match, ensuring we
        ;; highlight the match as code but highlight the rest as as
        ;; comments.
        (refs--unindent-rigidly
         (concat
          (propertize before-match 'face 'font-lock-comment-face)
          (refs--syntax-highlight (buffer-substring start-pos end-pos))
          (propertize after-match 'face 'font-lock-comment-face)))))))

(defun refs--find-file (button)
  "Open the file referenced by BUTTON."
  (find-file (button-get button 'path))
  (goto-char (point-min)))

(define-button-type 'refs-path-button
  'action 'refs--find-file
  'follow-link t
  'help-echo "Open file")

(defun refs--path-button (path)
  "Return a button that navigates to PATH."
  (with-temp-buffer
    (insert-text-button
     (f-abbrev path)
     :type 'refs-path-button
     'path path)
    (buffer-string)))

(defun refs--show-results (symbol results)
  "Given a list where each element takes the form \(forms . buffer\),
render a friendly results buffer."
  (let ((buf (get-buffer-create (format "*refs: %s*" symbol))))
    (switch-to-buffer buf)
    (setq buffer-read-only nil)
    (erase-buffer)
    (insert (format "Found %s results in %s files.\n\n"
                    (-sum (--map (length (car it)) results))
                    (length results)))
    (--each results
      (-let* (((forms . buf) it)
              (path (with-current-buffer buf refs--path)))
        (insert
         (propertize "File: " 'face 'bold)
         (refs--path-button path) "\n")
        (--each forms
          (-let [(_ start-pos end-pos) it]
            (insert (format "%s\n" (refs--containing-lines buf start-pos end-pos)))))
        (insert "\n")))
    (goto-char (point-min))
    ;; Use special-mode so 'q' kills the buffer.
    (special-mode)
    (setq buffer-read-only t)))

(defun refs--search (symbol)
  "Display all the references to SYMBOL, a function or macro."
  (let* ((loaded-paths (refs--loaded-files))
         (total-paths (length loaded-paths))
         (loaded-src-bufs (-map #'refs--contents-buffer loaded-paths)))
    ;; Use unwind-protect to ensure we always cleanup temporary
    ;; buffers, even if the user hits C-g.
    (unwind-protect
        (let* ((matching-forms (--map-indexed
                                (progn
                                  (when (zerop (mod it-index 10))
                                    (message "Searched %s/%s files" it-index total-paths))
                                  (refs--find-calls it symbol))
                                loaded-src-bufs))
               (forms-and-bufs (-zip matching-forms loaded-src-bufs))
               ;; Remove buffers where we didn't find any matches.
               (forms-and-bufs (--filter (car it) forms-and-bufs)))

          (message "Searched %s/%s files" total-paths total-paths)
          (refs--show-results symbol forms-and-bufs))
      ;; Clean up temporary buffers.
      (--each loaded-src-bufs (kill-buffer it)))))

(defun refs-function (symbol)
  "Display all the references to SYMBOL, a function."
  (interactive
   ;; TODO: default to function at point.
   (list (read (completing-read
                "Function: "
                (refs--filter-obarray #'functionp)))))
  (refs--search symbol))

(defun refs-macro (symbol)
  "Display all the references to SYMBOL, a macro."
  (interactive
   (list (read (completing-read
                "Macro: "
                (refs--filter-obarray #'macrop)))))
  (refs--search symbol))

;; TODO: currently we always search for function forms, which is
;; wrong.

(defun refs-special (symbol)
  "Display all the references to SYMBOL, a macro."
  (interactive
   (list (read (completing-read
                "Macro: "
                (refs--filter-obarray #'special-form-p)))))
  (refs--search symbol))

;; TODO: these docstring are poor and don't say where we search.

(defun refs-variable (symbol)
  "Display all the references to SYMBOL, a variable."
  (interactive
   (list (read (completing-read
                "Variable: "
                (refs--filter-obarray
                 ;; TODO: is there a built-in predicate function for
                 ;; this?
                 (lambda (sym)
                   (and (not (special-form-p sym))
                        (not (functionp sym)))))))))
  (refs--search symbol))

(defun refs-symbol (symbol)
  "Display all the references to SYMBOL."
  (interactive
   (list (read (completing-read
                "Symbol: "
                (refs--filter-obarray (lambda (_) t))))))
  (refs--search symbol))

;; TODO: refs-variable, refs-any, refs-special

(defmacro refs--print-time (&rest body)
  "Evaluate BODY, and print the time taken."
  `(let ((start-time (float-time)))
     ,@body
     (message "Took %s seconds"
              (- (float-time) start-time))))

(defun refs--bench ()
  "Measure runtime of searching."
  (interactive)
  (message "Searching for 'mod")
  (refs--print-time (refs--search 'mod))
  (message "Searching for 'when")
  (refs--print-time (refs--search 'when))
  (message "Formatting 10,000 results")
  (let ((forms (-repeat 10000 (list '(ignored) 1 64)))
        (buf (generate-new-buffer " *dummy-refs-buf*")))
    (with-current-buffer buf
      (insert "(defun foo (bar) (if bar nil (with-current-buffer bar))) ;; blah")
      (setq-local refs--path "/tmp/foo.el"))
    (refs--print-time
     (refs--show-results 'foo (list (cons forms buf))))
    (kill-buffer buf)))

(defun refs--report-loc ()
  "Report the total number of lines of code searched."
  (let* ((loaded-paths (refs--loaded-files))
         (loaded-src-bufs (-map #'refs--contents-buffer loaded-paths))
         (total-lines (-sum (--map (with-current-buffer it
                                     (line-number-at-pos (point-max)))
                                   loaded-src-bufs))))
    ;; Clean up temporary buffers.
    (--each loaded-src-bufs (kill-buffer it))
    (message "Total LOC: %s" total-lines)))

(provide 'refs)
;;; refs.el ends here
