;;; refs.el --- find callers of elisp functions or macros  -*- lexical-binding: t; -*-

;; Copyright (C) 2016  

;; Author: Wilfred Hughes <me@wilfred.me.uk>
;; Version: 0.1
;; Keywords: lisp
;; Package-Requires: ((dash "2.12.0") (f "0.18.2") (ht "2.1") (list-utils "0.4.4") (loop "2.1"))

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
(eval-when-compile (require 'cl-lib))

(defsubst refs--start-pos (end-pos)
  "Find the start position of form ending at END-FORM
in the current buffer."
  (scan-sexps end-pos -1))

(defun refs--sexp-positions (buffer start-pos end-pos)
  "Return a list of start and end positions of all the sexps
between START-POS and END-POS (excluding ends) in BUFFER."
  (let ((positions nil)
        (current-pos (1+ start-pos)))
    (with-current-buffer buffer
      (condition-case _err
          ;; Loop until we can't read any more.
          (loop-while t
            (let* ((sexp-end-pos (scan-sexps current-pos 1))
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
Returns a list (form start-pos end-pos).

Positions are 1-indexed, consistent with `point'."
  (let* ((form (read (current-buffer)))
         (end-pos (point))
         (start-pos (refs--start-pos end-pos)))
    (list form start-pos end-pos)))

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

(defun refs--find-calls-1 (buffer form start-pos end-pos symbol)
  "If FORM contains any calls to SYMBOL, return those subforms, along
with their start and end positions.

Returns nil otherwise.

This is basic static analysis, so indirect function calls are
ignored."
  ;; TODO: Handle funcall to static symbols too.
  ;; TODO: Handle sharp-quoted function references.
  ;; TODO: (defun foo (bar baz)) is not a function call to bar.
  (cond
   ;; Base case: are we looking at (symbol ...)?
   ((and (consp form) (eq (car form) symbol))
    (list (list form start-pos end-pos)))
   ;; Recurse, so we can find (... (symbol ...) ...)
   ((and (consp form) (not (list-utils-improper-p form)))
    (let ((sexp-positions (refs--sexp-positions buffer start-pos end-pos))
          (found-calls nil))
      ;; Iterate through the subforms, calculating matching paren
      ;; positions so we know where we are in the source.
      (dolist (subform-and-pos (-zip form sexp-positions))
        (let ((subform (car subform-and-pos))
              (subform-start-end (cdr subform-and-pos)))
          (when (consp subform)
            (let* ((subform-start (car subform-start-end))
                   (subform-end (cadr subform-start-end)))
              (push
               (refs--find-calls-1 buffer subform
                                   subform-start subform-end symbol)
               found-calls)))))
      ;; Concat any results from the subforms.
      (-non-nil (apply #'append (nreverse found-calls)))))
   ;; If it's not a cons cell, it's definitely not a call.
   (t
    nil)))

(defun refs--find-calls (forms-with-positions buffer symbol)
  "If FORMS-WITH-POSITIONS contain any calls to SYMBOL,
return those subforms, along with their positions."
  (-non-nil
   (--mapcat
    ;; TODO: Use -let and destructuring to simplify this, and likewise
    ;; with cadr above.
    (let ((form (nth 0 it))
          (start-pos (nth 1 it))
          (end-pos (nth 2 it)))
      (refs--find-calls-1 buffer form start-pos end-pos symbol))
    forms-with-positions)))

(defun refs--functions ()
  "Return a list of all symbols that are variables."
  (let (symbols)
    (mapatoms (lambda (symbol)
                (when (functionp symbol)
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
      (insert-file-contents path))
    fresh-buffer))

;; TODO: rename to :-extract-snippet.
(defun refs--containing-lines (buffer start-pos end-pos)
  "Return a string, all the lines in BUFFER that are between
START-POS and END-POS (inclusive).

For the characters that are between START-POS and END-POS,
propertize them."
  (let (section-start section-end section)
    (with-current-buffer buffer
      ;; Expand START-POS and END-POS to line boundaries.
      (goto-char start-pos)
      (beginning-of-line)
      (setq section-start (point))
      (goto-char end-pos)
      (end-of-line)
      (setq section-end (point))

      ;; Extract the section we're interested in.
      (setq section (buffer-substring section-start section-end)))
    ;; Find the positions where we want to start the match
    ;; highlighting.
    (let* ((match-start (- start-pos section-start))
           (match-end (- end-pos section-start)))
      (concat (substring section 0 match-start)
              (propertize (substring section match-start match-end)
                          'face 'font-lock-variable-name-face)
              (substring section match-end)))))

;; TODO: find proper faces for results buffer rather than
;; types and variables.
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
        (insert (propertize (format "File: %s\n" (f-short path))
                            'face 'font-lock-type-face))
        (--each forms
          (-let [(_ start-pos end-pos) it]
            (insert (format "%s\n" (refs--containing-lines buf start-pos end-pos)))))
        (insert "\n")))
    (goto-char (point-min))
    ;; Use special-mode so 'q' kills the buffer.
    (special-mode)
    (setq buffer-read-only t)))

;; suggestion: format is a great function to use
(defun refs-function (symbol)
  "Display all the references to SYMBOL, a function."
  (interactive
   ;; TODO: default to function at point.
   (list (read (completing-read "Function: " (refs--functions)))))

  (let* ((loaded-paths (refs--loaded-files))
         (total-paths (length loaded-paths))
         (loaded-src-bufs (-map #'refs--contents-buffer loaded-paths))
         (matching-forms (--map-indexed
                          (progn
                            (when (zerop (mod it-index 10))
                              (message "Searched %s/%s files" it-index total-paths))
                            (refs--find-calls (refs--read-all-buffer-forms it) it symbol))
                          loaded-src-bufs))
         (forms-and-bufs (-zip matching-forms loaded-src-bufs))
         ;; Remove paths where we didn't find any matches.
         (forms-and-bufs (--filter (car it) forms-and-bufs)))
    (message "Searched %s/%s files" total-paths total-paths)
    (refs--show-results symbol forms-and-bufs)
    ;; Clean up temporary buffers.
    (--each loaded-src-bufs (kill-buffer it))))

(provide 'refs)
;;; refs.el ends here
