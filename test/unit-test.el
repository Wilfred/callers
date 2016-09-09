(require 'ert)
(require 'refs)

(ert-deftest refs--unindent-rigidly ()
  "Ensure we unindent by the right amount."
  ;; Take the smallest amount of indentation, (2 in this case), and
  ;; unindent by that amount.
  (should
   (equal
    (refs--unindent-rigidly "   foo\n  bar\n    baz")
    " foo\nbar\n  baz"))
  ;; If one of the lines has no indent, do nothing.
  (should
   (equal
    (refs--unindent-rigidly "foo\n bar")
    "foo\n bar"))
  ;; Consider tabs to be equivalent to `tab-width' spaces.
  (let ((tab-width 8))
    (should
     (equal
      (refs--unindent-rigidly "\tx\n    y")
      "    x\ny"))))

(ert-deftest refs--propertize-substring ()
  "Ensure the string has the same contents after adding properties."
  (should
   ;; Note that `equal' ignores properties
   (equal
    (refs--propertize-substring "foo bar baz" 4 7 'underline t)
    "foo bar baz")))

(ert-deftest refs-function ()
  "Smoke test for `refs-function'."
  (refs-function 'format))
