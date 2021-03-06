;;; emojify.el --- Display emojis in Emacs           -*- lexical-binding: t; -*-

;; Copyright (C) 2015  Iqbal Ansari

;; Author: Iqbal Ansari <iqbalansari02@yahoo.com>
;; Keywords: multimedia, convenience
;; URL: https://github.com/iqbalansari/emacs-emojify
;; Version: 0.3
;; Package-Requires: ((seq "1.11") (ht "2.0") (emacs "24.3"))

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

;; This package displays emojis in Emacs similar to how Github, Slack etc do.  It
;; can display plain ascii like ':)' as well as Github style emojis like ':smile:'
;;
;; It provides a minor mode `emojify-mode' to enable display of emojis in a buffer.
;; To enable emojify mode globally use `global-emojify-mode'
;;
;; For detailed documentation see the projects README file at
;; https://github.com/iqbalansari/emacs-emojify



;;; Code:

(require 'seq)
(require 'ht)

(require 'json)
(require 'regexp-opt)
(require 'jit-lock)
(require 'pcase)
(require 'tar-mode)



;; Satisfying the byte-compiler
;; We do not "require" these functions but if `org-mode' is active we use them

;; Required to determine point is in an org-list
(declare-function org-at-item-p "org-list")
(declare-function org-at-heading-p "org")

;; Required to determine point is in an org-src block
(declare-function org-element-type "org-element")
(declare-function org-element-at-point "org-element")

;; Shouldn't require 'jit-lock be enough :/
(defvar jit-lock-start)
(defvar jit-lock-end)



;; Compatibility functions

(defun emojify-default-font-height ()
  "Return the height in pixels of the current buffer's default face font.

`default-font-height' seems to be available only on Emacs versions after 24.3.
This provides a compatibility version for previous versions."
  (if (fboundp 'default-font-height)
      (default-font-height)
    (let ((default-font (face-font 'default)))
      (cond
       ((and (display-multi-font-p)
             ;; Avoid calling font-info if the frame's default font was
             ;; not changed since the frame was created.  That's because
             ;; font-info is expensive for some fonts, see bug #14838.
             (not (string= (frame-parameter nil 'font) default-font)))
        (aref (font-info default-font) 3))
       (t (frame-char-height))))))

(defun emojify-overlays-at (pos &optional sorted)
  "Return a list of the overlays that contain the character at POS.
If SORTED is non-nil, then sort them by decreasing priority.

The SORTED argument was introduced in Emacs 24.4, along with the incompatible
change that overlay priorities can be any Lisp object (earlier they were
restricted to integer and nil).  This version uses the SORTED argument of
`overlays-at' on Emacs version 24.4 onwards and manually sorts the overlays by
priority on lower versions."
  (if (version< emacs-version "24.4")
      (let ((overlays-at-pos (overlays-at pos)))
        (if sorted
            (seq-sort (lambda (overlay1 overlay2)
                        (if (and (overlay-get overlay2 'priority)
                                 (overlay-get overlay1 'priority))
                            ;; If both overlays have priorities compare them
                            (< (overlay-get overlay1 'priority)
                               (overlay-get overlay2 'priority))
                          ;; Otherwise overlay with nil priority is sorted below
                          ;; the one with integer value otherwise preserve order
                          (not (overlay-get overlay1 'priority))))
                      overlays-at-pos)
          overlays-at-pos))
    (overlays-at pos sorted)))



;; Utility functions

(defvar emojify-debug-mode nil
  "Signal errors when emoji redisplay fails.

By default emojify silences any errors during emoji redisplay.  This is done
since emojis are redisplayed using jit-lock (the same mechanism used for
font-lock) as such any bugs in the code can cause other important things to
fail.

Set `emojify-debug-mode' to non-nil to instruct emojify to not silence any
errors during operation.")

(defmacro emojify-execute-ignoring-errors-unless-debug (&rest forms)
  "Execute FORMS ignoring errors unless `emojify-debug-mode' is non-nil."
  (declare (debug t) (indent 0))
  `(if emojify-debug-mode
       (progn
         ,@forms)
     (ignore-errors
       ,@forms)))

(defmacro emojify-with-saved-buffer-state (&rest forms)
  "Execute FORMS saving current buffer state.

This saves point and mark, `match-data' and buffer modification state it also
inhibits buffer change, point motion hooks."
  (declare (debug t) (indent 0))
  `(let ((inhibit-point-motion-hooks t))
     (with-silent-modifications
       (save-match-data
         (save-excursion
           (save-restriction
             (widen)
             ,@forms))))))

(defmacro emojify-do-for-emojis-in-region (beg end &rest forms)
  "For all emojis between BEG and END, execute the given FORMS.

During the execution `emoji-start' and `emoji-end' are bound to the start
and end of the emoji for which the form is being executed."
  (declare (debug t) (indent 2))
  `(let ((--emojify-loop-current-pos ,beg)
         (--emojify-loop-end ,end)
         emoji-start)
     (while (and (> --emojify-loop-end --emojify-loop-current-pos)
                 (setq emoji-start (text-property-any --emojify-loop-current-pos --emojify-loop-end 'emojified t)))
       (let ((emoji-end (+ emoji-start
                           (length (get-text-property emoji-start 'emojify-text)))))
         ,@forms
         (setq --emojify-loop-current-pos emoji-end)))))

(defun emojify-message (format-string &rest args)
  "Log debugging messages to buffer named 'emojify-log'.

This is a substitute to `message' since using it during redisplay causes errors.
FORMAT-STRING and ARGS are same as the arguments to `message'."
  (when emojify-debug-mode
    (emojify-with-saved-buffer-state
      (with-current-buffer (get-buffer-create "emojify-log")
        (goto-char (point-max))
        (insert (apply #'format format-string args))
        (insert "\n")))))

(defun emojify--get-relevant-region ()
  "Try getting region in buffer that completely covers the current window.

This is used instead of directly using `window-start' and `window-end', since
they return the values corresponding buffer in currently selected window, which
is incorrect if the buffer where there are called is not actually the buffer
visible in the selected window."
  (let* ((window-size (- (window-end) (window-start)))
         (start (max (- (point) window-size) (point-min)))
         (end (min (+ (point) window-size) (point-max))))
    (cons start end)))



;; Customizations for control how emojis are displayed

(defgroup emojify nil
  "Customization options for emojify"
  :group 'display
  :prefix "emojify-")

(defcustom emojify-emoji-json
  (expand-file-name "data/emoji.json"
                    (cond (load-file-name (file-name-directory load-file-name))
                          ((locate-library "emojify") (file-name-directory (locate-library "emojify")))
                          (t default-directory)))
  "The path to JSON file containing the configuration for displaying emojis."
  :type 'file
  :group 'emojify)

(defvar emojify-emoji-set-json
  (let ((json-array-type 'list)
        (json-object-type 'hash-table))
    (json-read-file (expand-file-name "data/emoji-sets.json"
                                      (cond (load-file-name (file-name-directory load-file-name))
                                            ((locate-library "emojify") (file-name-directory (locate-library "emojify")))
                                            (t default-directory))))))

(defcustom emojify-emoji-set "emojione-v2-22"
  "The emoji set used to display emojis."
  :type (append '(radio :tag "Emoji set")
                (mapcar (lambda (set) (list 'const set))
                        (ht-keys emojify-emoji-set-json)))
  :group 'emojify)

(defcustom emojify-emojis-dir
  (locate-user-emacs-file "emojis")
  "Path to the directory containing the emoji images."
  :type 'directory
  :group 'emojify)

(defcustom emojify-image-dir
  (expand-file-name emojify-emoji-set
                    emojify-emojis-dir)
  "Path to emoji images.")

(defcustom emojify-display-style
  'image
  "How the emoji's be displayed.

Possible values are
`image'   - Display emojis using images, this requires images are supported by
            user's Emacs installation
`unicode' - Display emojis using unicode characters, this works well on
            platforms with good emoji fonts.  In this case the emoji text
            ':wink:' will be substituted with 😉.
`ascii'   - Display emojis as ascii characters, this is simplest and does not
            require any external dependencies.  In this cases emoji text like
            ':wink:' are substituted with ascii equivalents like ';)'"
  :type '(radio :tag "Emoji display style"
                (const :tag "Display emojis as images" image)
                (const :tag "Display emojis as unicode characters" unicode)
                (const :tag "Display emojis as ascii string" ascii))
  :group 'emojify)



;; Customizations to control the enabling of emojify-mode

(defcustom emojify-inhibit-major-modes
  '(dired-mode
    doc-view-mode
    pdf-view-mode
    image-mode
    help-mode
    magit-popup-mode
    ert-results-mode
    compilation-mode
    proced-mode
    mu4e-headers-mode)
  "Major modes where emojify mode should not be enabled."
  :type '(repeat symbol)
  :group 'emojify)

(defcustom emojify-inhibit-in-buffer-functions
  '(minibufferp emojify-helm-buffer-p)
  "Functions used inhibit emojify-mode in a buffer.

These functions are called with one argument, the buffer where emojify-mode
is about to be enabled, emojify is not enabled if any of the functions return
a non-nil value."
  :type 'hook
  :group 'emojify)

(defvar emojify-inhibit-emojify-in-current-buffer-p nil
  "Should emojify be inhibited in current buffer.

This is a buffer local variable that can be set to inhibit enabling of
emojify in a buffer.")
(make-variable-buffer-local 'emojify-inhibit-emojify-in-current-buffer-p)

(defun emojify-ephemeral-buffer-p (buffer)
  "Determine if BUFFER is an ephemeral/temporary buffer."
  (string-match-p "^ " (buffer-name buffer)))

(defun emojify-inhibit-major-mode-p (buffer)
  "Determine if user has disabled the `major-mode' enabled for the BUFFER.

Returns non-nil if the buffer's major mode is part of `emojify-inhibit-major-modes'"
  (with-current-buffer buffer
    (apply #'derived-mode-p emojify-inhibit-major-modes)))

(defun emojify-helm-buffer-p (buffer)
  "Determine if the current BUFFER is a helm buffer."
  (string-match-p "\\*helm" (buffer-name buffer)))

(defun emojify-buffer-p (buffer)
  "Determine if `emojify-mode' should be enabled for given BUFFER.

`emojify-mode' mode is not enabled in temporary buffers.  Additionally user
can customize `emojify-inhibit-major-modes' and
`emojify-inhibit-in-buffer-functions' to disabled emojify in additional buffers."
  (not (or emojify-inhibit-emojify-in-current-buffer-p
           (emojify-ephemeral-buffer-p (current-buffer))
           (emojify-inhibit-major-mode-p (current-buffer))
           (buffer-base-buffer buffer)
           (run-hook-with-args-until-success 'emojify-inhibit-in-buffer-functions buffer))))



;; Customizations to control display of emojis

(defvar emojify-emojis nil
  "Data about the emojis, this contains only the emojis that come with emojify.")

(defvar emojify-regexps nil
  "Regexp to match text to emojified.")

(defvar emojify-emoji-style-change-hooks nil
  "Hooks run when emoji style changes.")

(defun emojify-set-emoji-data ()
  "Read the emoji data for STYLES and set the regexp required to search them."
  (setq emojify-emojis (let ((json-array-type 'list)
                             (json-object-type 'hash-table))
                         (json-read-file emojify-emoji-json)))

  (setq emojify-regexps (seq-map #'regexp-opt
                                 (seq-partition (ht-keys emojify-emojis)
                                                1000))))

;;;###autoload
(defun emojify-set-emoji-styles (styles)
  "Set the type of emojis that should be displayed.

STYLES is the styles emoji styles that should be used, see `emojify-emoji-styles'"
  (when (not (listp styles))
    (setq styles (list styles))
    (warn "`emojify-emoji-style' has been deprecated use `emojify-emoji-styles' instead!"))

  (setq-default emojify-emoji-styles styles)

  (run-hooks 'emojify-emoji-style-change-hooks))

(defcustom emojify-emoji-styles
  '(ascii unicode github)
  "The type of emojis that should be displayed.

These can have one of the following values

`ascii'   - Display only ascii emojis for example ';)'
`unicode' - Display only unicode emojis for example '😉'
`github'  - Display only github style emojis for example ':wink:'"
  :type '(set
          (const :tag "Display only ascii emojis" ascii)
          (const :tag "Display only github emojis" github)
          (const :tag "Display only unicode codepoints" unicode))
  :set (lambda (_ value) (emojify-set-emoji-styles value))
  :group 'emojify)

(defcustom emojify-program-contexts
  '(comments string code)
  "Contexts where emojis can be displayed in programming modes.

Possible values are
`comments' - Display emojis in comments
`string'   - Display emojis in strings
`code'     - Display emojis in code (this is applicable only for unicode emojis)"
  :type '(set :tag "Contexts where emojis should be displayed in programming modes"
              (const :tag "Display emojis in comments" comments)
              (const :tag "Display emojis in string" string)
              (const :tag "Display emojis in code" code))
  :group 'emojify)

(defcustom emojify-prog-contexts
  'both
  "Contexts where emojis can be displayed in programming modes.

Possible values are
`comments' - Display emojis only in comments
`string'   - Display emojis only in strings
`both'     - Display emojis in comments and strings
`none'     - Do not display emojis in programming modes"
  :type '(radio :tag "Contexts where emojis should be displayed in programming modes"
                (const :tag "Only in comments" comments)
                (const :tag "Only in string" string)
                (const :tag "Both in comments and string" both)
                (const :tag "Do not display emojis in programming modes" none))
  :set (lambda (_ value)
         (setq emojify-program-contexts (pcase value
                                          (`comments '(comments))
                                          (`string '(string))
                                          (`both '(comments string code))
                                          (`none '()))))
  :group 'emojify)

(defcustom emojify-inhibit-functions
  '(emojify-in-org-tags-p emojify-in-org-list-p)
  "Functions used to determine given emoji should displayed at current point.

These functions are called with 3 arguments, the text to be emojified, the start
of emoji text and the end of emoji text.  These functions are called with the
buffer where emojis are going to be displayed selected."
  :type 'hook
  :group 'emojify)

(defun emojify-in-org-tags-p (match _beg _end)
  "Determine whether the point is on `org-mode' tag.

MATCH, BEG and END are the text currently matched emoji and the start position
and end position of emoji text respectively.

Easiest would have to inspect face at point but unfortunately, there is no
way to guarantee that we run after font-lock"
  (and (memq major-mode '(org-mode org-agenda-mode))
       (string-match-p ":.*:" match)
       (org-at-heading-p)
       (not (save-excursion
              (save-match-data
                (search-forward-regexp "\\s-" (line-end-position) t))))))

(defun emojify-in-org-list-p (&rest ignored)
  "Determine whether the point is in `org-mode' list.

The arguments IGNORED are, well ignored"
  (and (eq major-mode 'org-mode)
       (org-at-item-p)))

(defun emojify-valid-program-context-p (emoji beg end)
  "Determine if emoji should be displayed for text between BEG and END.

This returns non-nil if the region is valid according to `emojify-program-contexts'"
  (when emojify-program-contexts
    (let* ((syntax-beg (syntax-ppss beg))
           (syntax-end (syntax-ppss end))
           (context (cond ((and (nth 3 syntax-beg)
                                (nth 3 syntax-end)) 'string)
                          ((and (nth 4 syntax-beg)
                                (nth 4 syntax-end)) 'comments)
                          (t 'code))))
      (and (memql context emojify-program-contexts)
           (if (equal context 'code)
               ;; If context if code display only unicode emojis
               (and (string= (ht-get emoji "style") "unicode")
                    (memql 'unicode emojify-emoji-styles))
             ;; No need to check for non-code context
             t)))))

(defun emojify-inside-org-src-p (point)
  "Return non-nil if POINT is inside `org-mode' src block.

This is used to inhibit display of emoji's in `org-mode' src blocks
since our mechanisms do not work in it."
  (when (eq major-mode 'org-mode)
    (save-excursion
      (goto-char point)
      (eq (org-element-type (org-element-at-point)) 'src-block))))

(defun emojify-looking-at-end-of-list-maybe (point)
  "Determine if POINT is end of a list.

This is not accurate since it restricts the region to scan to
the visible area."
  (let* ((area (emojify--get-relevant-region))
         (beg (car area))
         (end (cdr area)))
    (save-restriction
      (narrow-to-region beg end)
      (let ((list-start (ignore-errors (scan-sexps point -1))))
        (when list-start
          ;; If we got a list start make sure both start and end
          ;; belong to same string/comment
          (let ((syntax-beg (syntax-ppss list-start))
                (syntax-end (syntax-ppss point)))
            (and list-start
                 (eq (nth 8 syntax-beg)
                     (nth 8 syntax-end)))))))))

(defun emojify-valid-ascii-emoji-context-p (beg end)
  "Determine if the okay to display ascii emoji between BEG and END."
  ;; The text is at the start of the buffer
  (and (or (not (char-before beg))
           ;; 32 space since ?  (? followed by a space) is not readable
           ;; 34 is "  since?" confuses font-lock
           ;; 41 is )  since?) (extra paren) confuses most packages
           (memq (char-syntax (char-before beg))
                 ;; space
                 '(32
                   ;; start/end of string
                   34
                   ;; whitespace syntax
                   ?-
                   ;; comment start
                   ?<
                   ;; comment end, this handles text at start of line immediately
                   ;; after comment line in a multiline comment
                   ?>)))
       ;; The text is at the end of the buffer
       (or (not (char-after end))
           (memq (char-syntax (char-after end))
                 ;; space
                 '(32
                   ;; start/end of string
                   34
                   ;; whitespace syntax
                   ?-
                   ;; punctuation
                   ?.
                   ;; closing braces
                   41
                   ;; comment end
                   ?>)))))



;; Obsolete vars

(define-obsolete-variable-alias 'emojify-emoji-style 'emojify-emoji-styles "0.2")
(define-obsolete-function-alias 'emojify-set-emoji-style 'emojify-set-emoji-styles "0.2")
(define-obsolete-variable-alias 'emojify-prog-contexts 'emojify-program-contexts "0.3")



;; Customizations to control the behaviour when point enters emojified text

(defcustom emojify-point-entered-behaviour 'echo
  "The behaviour when point enters, an emojified text.

It can be one of the following
`echo'    - Echo the underlying text in the minibuffer
`uncover' - Display the underlying text while point is on it
function  - It is called with 4 arguments
            1) buffer where emoji text is
            2) the emoji text
            3) starting position of emoji text
            4) ending position of emoji text

Does nothing if the value is anything else."
  ;; TODO: Mention custom function
  :type '(radio :tag "Behaviour when point enters an emoji"
                (const :tag "Echo the underlying emoji text in the minibuffer" echo)
                (const :tag "Uncover (undisplay) the underlying emoji text" uncover))
  :group 'emojify)

(defcustom emojify-show-help t
  "If non-nil the underlying text is displayed in a popup when mouse moves over it."
  :type 'boolean
  :group 'emojify)

(defun emojify--uncover-emoji (buffer match-beginning match-end)
  "Uncover emoji in BUFFER between MATCH-BEGINNING and MATCH-END."
  (emojify-with-saved-buffer-state
    (add-text-properties match-end
                         match-beginning
                         (list 'display nil
                               'point-left (emojify--get-point-left-function buffer
                                                                             match-beginning
                                                                             match-end)
                               'point-entered nil))))

(defun emojify-point-entered-function (_old-point new-point)
  "Create a function to be executed when point enters an emojified text.

OLD-POINT and NEW-POINT are the point before entering and after entering."
  (let* ((text-props (text-properties-at new-point))
         (buffer (plist-get text-props 'emojify-buffer))
         (match (plist-get text-props 'emojify-text))
         (match-beginning (plist-get text-props 'emojify-beginning))
         (match-end (plist-get text-props 'emojify-end)))
    (when (eq buffer (current-buffer))
      (cond ((and (eq emojify-point-entered-behaviour 'echo)
                  ;; Do not echo in isearch-mode
                  (not isearch-mode)
                  (not (active-minibuffer-window))
                  (not (current-message)))
             (message (substring-no-properties match)))
            ((eq emojify-point-entered-behaviour 'uncover)
             (emojify--uncover-emoji buffer match-beginning match-end))
            ((functionp 'emojify-point-entered-behaviour)
             (funcall emojify-point-entered-behaviour buffer match match-beginning match-end)))

      ;; Uncover at point anyway in isearch-mode
      (when (and isearch-mode
                 (not (eq emojify-point-entered-behaviour 'uncover)))
        (emojify--uncover-emoji buffer match-beginning match-end)))))

(defun emojify-help-function (_window _string pos)
  "Function to get help string to be echoed when point/mouse into the point.

To understand WINDOW, STRING and POS see the function documentation for
`help-echo' text-property."
  (when (and emojify-show-help
             (not isearch-mode)
             (not (active-minibuffer-window))
             (not (current-message)))
    (plist-get (text-properties-at pos) 'emojify-text)))



;; Core functions and macros

(defvar emojify-emoji-keymap (let ((map (make-sparse-keymap)))
                               (define-key map [remap delete-char] #'emojify-delete-emoji-forward)
                               (define-key map [remap delete-forward-char] #'emojify-delete-emoji-forward)
                               (define-key map [remap backward-delete-char] #'emojify-delete-emoji-backward)
                               (define-key map [remap delete-backward-char] #'emojify-delete-emoji-backward)
                               (define-key map [remap backward-delete-char-untabify] #'emojify-delete-emoji-backward)
                               map))

(defun emojify--get-point-left-function (buffer match-beginning match-end)
  "Create a function that can be executed in point-left hook for emoji text.

BUFFER is the buffer where the text is from, MATCH-BEGINNING and MATCH-END.
mark the start and end of region containing the text."
  (lambda (_old-point new-point)
    (when (and (equal buffer (current-buffer))
               (or (< match-end new-point)
                   (< new-point match-beginning)))
      (emojify-with-saved-buffer-state
        (let ((current-display (get-text-property match-beginning 'emojify-display)))
          (add-text-properties match-beginning match-end (list 'display current-display
                                                               'point-left nil
                                                               'point-entered #'emojify-point-entered-function)))))))

(defun emojify--get-point-col-and-line (point)
  "Return a cons of containing the column number and line at POINT."
  (save-excursion
    (goto-char point)
    (cons (current-column) (line-number-at-pos))))

;; These should be bound dynamically by functions calling
;; `emojify--inside-rectangle-selection-p' and
;; `emojify--inside-non-rectangle-selection-p' to region-beginning and
;; region-end respectively. This is needed mark the original region which is
;; impossible to get after point moves during processing.
(defvar emojify-region-beg nil)
(defvar emojify-region-end nil)

(defun emojify--inside-rectangle-selection-p (beg end)
  "Check if region marked by BEG and END is inside a rectangular selection.

In addition to explicit the parameters BEG and END, calling functions should
also dynamically bind `emojify-region-beg' and `emojify-region-end' to beginning
and end of region respectively."
  (when (and emojify-region-beg
             (bound-and-true-p rectangle-mark-mode))
    (let ((rect-beg (emojify--get-point-col-and-line emojify-region-beg))
          (rect-end (emojify--get-point-col-and-line emojify-region-end))
          (emoji-start-pos (emojify--get-point-col-and-line beg))
          (emoji-end-pos (emojify--get-point-col-and-line end)))
      (or (and (<= (car rect-beg) (car emoji-start-pos))
               (<= (car emoji-start-pos) (car rect-end))
               (<= (cdr rect-beg) (cdr emoji-start-pos))
               (<= (cdr emoji-start-pos) (cdr rect-end)))
          (and (<= (car rect-beg) (car emoji-end-pos))
               (<= (car emoji-end-pos) (car rect-end))
               (<= (cdr rect-beg) (cdr emoji-end-pos))
               (<= (cdr emoji-end-pos) (cdr rect-end)))))))

(defun emojify--inside-non-rectangle-selection-p (beg end)
  "Check if region marked by BEG and END is inside a regular selection.

In addition to the explicit parameters BEG and END, calling functions should
also dynamically bind `emojify-region-beg' and `emojify-region-end' to beginning
and end of region respectively."
  (when (and emojify-region-beg
             (region-active-p)
             (not (bound-and-true-p rectangle-mark-mode)))
    (or (and (<= emojify-region-beg beg)
             (<= beg emojify-region-end))
        (and (<= emojify-region-beg end)
             (<= end emojify-region-end)))))

(defun emojify--region-background-face-maybe (beg end)
  "Get the region for emoji between BEG and END.

This returns nil if the emojis between BEG and END do not fall in region."
  ;; `redisplay-highlight-region-function' was not defined in Emacs 24.3
  (when (and (or (not (boundp 'redisplay-highlight-region-function))
                 (equal (default-value 'redisplay-highlight-region-function) redisplay-highlight-region-function))
             (or (emojify--inside-non-rectangle-selection-p beg end)
                 (emojify--inside-rectangle-selection-p beg end)))
    (face-background 'region)))

(defun emojify--overlay-face-background (face)
  "Get background for given overlay FACE.

This similar to `face-background' except it handles different values possible
for overlay face including anonymous faces and list of faces.  Unlike
`face-background' it always looks up inherited faces if background is not
directly defined on the face."
  (if (memq (type-of face) '(string symbol))
      (and (facep face)
           (face-background face nil 'default))
    (and (consp face)
         ;; Handle anonymous faces
         (or (or (plist-get face :background)
                 (emojify--face-background (car (plist-get face :inherit))))
             ;; Possibly a list of faces
             (emojify--overlay-face-background (car face))))))

(defun emojify--overlay-background (beg)
  "Get the overlay face for point BEG."
  (let* ((overlay-backgrounds (delq nil (seq-map (lambda (overlay)
                                                   (and (overlay-get overlay 'face)
                                                        (emojify--overlay-face-background (overlay-get overlay 'face))))
                                                 (emojify-overlays-at beg t)))))
    (car (last overlay-backgrounds))))

(defun emojify--face-background-at-point (beg)
  "Get the background color for emoji at BEG."
  (save-excursion
    (goto-char beg)
    (let ((point-face (face-at-point)))
      (when point-face
        (face-background point-face)))))

(defun emojify--get-image-background (beg end)
  "Get the color to be used as background for emoji between BEG and END.

Ideally `emojify--overlay-background' should have been enough to handle
selection, but for some reason it does not work well."
  (or (emojify--region-background-face-maybe beg end)
      ;; TODO: `emojify--face-background-at-point' might already be
      ;; handling overlay faces as such `emojify--overlay-background'
      ;; might be redundant, need to verify this though
      (emojify--overlay-background beg)
      (emojify--face-background-at-point beg)
      (face-background 'default)))

(defun emojify--get-image-display (data beg end)
  "Get the display text property to display the emoji as an image.

DATA holds the emoji data, BEG and END delimit the region where emoji will
be displayed."
  (let* ((image-file (expand-file-name (ht-get data "image")
                                       emojify-image-dir))
         (image-type (intern (upcase (file-name-extension image-file)))))
    (when (file-exists-p image-file)
      (create-image image-file
                    ;; use imagemagick if available and supports PNG images
                    ;; (allows resizing images)
                    (when (and (fboundp 'imagemagick-types)
                               (memq image-type (imagemagick-types)))
                      'imagemagick)
                    nil
                    :ascent 'center
                    :heuristic-mask t
                    :background (emojify--get-image-background beg end)
                    ;; no-op if imagemagick is not available
                    :height (emojify-default-font-height)))))

(defun emojify--get-unicode-display (data _beg _end)
  "Get the display text property to display the emoji as an unicode character.

DATA holds the emoji data, _BEG and _END delimit the region where emoji will
be displayed."
  (let* ((unicode (ht-get data "unicode"))
         (characters (when unicode
                       (string-to-vector unicode))))
    (when (seq-every-p #'char-displayable-p characters)
      unicode)))

(defun emojify--get-ascii-display (data _beg _end)
  "Get the display text property to display the emoji as an ascii characters.

DATA holds the emoji data, _BEG and _END delimit the region where emoji will
be displayed."
  (ht-get data "ascii"))

(defun emojify--get-text-display-props (emoji beg end)
  "Get the display property for an EMOJI.

TEXT is the text to be displayed as emoji, BEG and END delimit the
region containing the emoji."
  (funcall (pcase emojify-display-style
             (`image #'emojify--get-image-display)
             (`unicode #'emojify--get-unicode-display)
             (`ascii #'emojify--get-ascii-display))
           emoji
           beg
           end))

(defun emojify-display-emojis-in-region (beg end)
  "Display emojis in region.

BEG and END are the beginning and end of the region respectively.
TODO: Skip emojifying if region is already emojified."
  (emojify-with-saved-buffer-state
    (seq-doseq (regexp emojify-regexps)
      (let (case-fold-search)
        (goto-char beg)
        (while (and (> end (point))
                    (search-forward-regexp regexp end t))
          (let* ((match-beginning (match-beginning 0))
                 (match-end (match-end 0))
                 (match (match-string-no-properties 0))
                 (buffer (current-buffer))
                 (emoji (ht-get emojify-emojis match)))

            (when (and (memql (intern (ht-get emoji "style"))
                              emojify-emoji-styles)
                       ;; Display unconditionally in non-prog mode
                       (or (not (derived-mode-p 'prog-mode 'tuareg--prog-mode 'comint-mode))
                           ;; In prog mode enable respecting `emojify-program-contexts'
                           (emojify-valid-program-context-p emoji match-beginning match-end))

                       ;; Display ascii emojis conservatively, since they have potential
                       ;; to be annoying consider d: in head:
                       (or (not (string= (ht-get emoji "style") "ascii"))
                           (emojify-valid-ascii-emoji-context-p match-beginning match-end))

                       (not (emojify-inside-org-src-p match-beginning))

                       ;; Inhibit possibly inside a list
                       ;; 41 is ?) but packages get confused by the extra closing paren :)
                       ;; TODO Report bugs to such packages
                       (not (and (eq (char-syntax (char-before match-end)) 41)
                                 (emojify-looking-at-end-of-list-maybe match-end)))

                       (not (run-hook-with-args-until-success 'emojify-inhibit-functions match match-beginning match-end)))

              (let ((display-prop (emojify--get-text-display-props emoji match-beginning match-end)))
                (when display-prop
                  (add-text-properties match-beginning
                                       match-end
                                       (list 'emojified t
                                             'emojify-display display-prop
                                             'display display-prop
                                             'emojify-buffer buffer
                                             'emojify-text match
                                             'emojify-beginning (copy-marker match-beginning)
                                             'emojify-end (copy-marker match-end)
                                             'yank-handler (list nil match)
                                             'keymap emojify-emoji-keymap
                                             'point-entered #'emojify-point-entered-function
                                             'help-echo #'emojify-help-function)))))))))))

(defun emojify-undisplay-emojis-in-region (beg end)
  "Undisplay the emojis in region.

BEG and END are the beginning and end of the region respectively"
  (emojify-with-saved-buffer-state
    (while (< beg end)
      ;; Get the start of emojified region in the region, the region is marked
      ;; with text-property `emojified' whose value is `t'. The region is marked
      ;; so that we do not inadvertently remove display or other properties
      ;; inserted by other packages.  This might fail too if a package adds any
      ;; of these properties between an emojified text, but that situation is
      ;; hopefully very rare and this is better than blindly removing all text
      ;; properties
      (let* ((emoji-start (text-property-any beg end 'emojified t))
             ;; Get the end emojified text, if we could not find the start set
             ;; emoji-end to region `end', this merely to make looping easier.
             (emoji-end (or (and emoji-start
                                 (text-property-not-all emoji-start end 'emojified t))
                            ;; If the emojified text is at the end of the region
                            ;; assume that end is the emojified text.
                            end)))
        ;; Proceed only if we got start of emojified text
        (when emoji-start
          ;; Remove the properties
          (remove-text-properties emoji-start emoji-end (append (list 'emojified t
                                                                      'display t
                                                                      'emojify-display t
                                                                      'point-entered t
                                                                      'point-left t
                                                                      'emojify-buffer t
                                                                      'emojify-text t
                                                                      'emojify-beginning t
                                                                      'emojify-end t
                                                                      'yank-handler t
                                                                      'keymap t
                                                                      'help-echo t
                                                                      'rear-nonsticky t))))
        ;; Setup the next iteration
        (setq beg emoji-end)))))

(defun emojify-redisplay-emojis-in-region (&optional beg end)
  "Redisplay emojis in region between BEG and END.

Redisplay emojis in the visible region if BEG and END are not specified"
  (let* ((area (emojify--get-relevant-region))
         (beg (or beg (car area)))
         (end (or end (cdr area))))
    (emojify-execute-ignoring-errors-unless-debug
      (emojify-undisplay-emojis-in-region beg end)
      (emojify-display-emojis-in-region beg end))))

(defun emojify-after-change-extend-region-function (beg end _len)
  "Extend the region to be emojified.

This simply extends the region to be fontified to the start of line at BEG and
end of line at END.  _LEN is ignored.

The idea is since an emoji cannot span multiple lines, redisplaying complete
lines ensures that all the possibly affected emojis are redisplayed."
  (let ((emojify-jit-lock-start (save-excursion
                                  (goto-char beg)
                                  (line-beginning-position)))
        (emojify-jit-lock-end (save-excursion
                                (goto-char end)
                                (line-end-position))))
    (setq jit-lock-start (if jit-lock-start
                             (min jit-lock-start emojify-jit-lock-start)
                           emojify-jit-lock-start))
    (setq jit-lock-end (if jit-lock-end
                           (max jit-lock-end emojify-jit-lock-end)
                         emojify-jit-lock-end))))



;; Electric delete functionality

(defun emojify--find-key-binding-ignoring-emojify-keymap (key)
  "Find the binding for given KEY ignoring the text properties at point.

This is needed since `key-binding' looks up in keymap text property as well
which is not what we want when falling back in `emojify-delete-emoji'"
  (let* ((key-binding (or (minor-mode-key-binding key)
                          (local-key-binding key)
                          (global-key-binding key))))
    (when key-binding
      (or (command-remapping key-binding
                             nil
                             (seq-filter (lambda (keymap)
                                           (not (equal keymap emojify-emoji-keymap)))
                                         (current-active-maps)))
          key-binding))))

(defun emojify-delete-emoji (point)
  "Delete emoji at POINT."
  (if (get-text-property point 'emojified)
      (delete-region (get-text-property point 'emojify-beginning)
                     (get-text-property point 'emojify-end))
    (call-interactively (emojify--find-key-binding-ignoring-emojify-keymap (this-command-keys)))))

(defun emojify-delete-emoji-forward ()
  "Delete emoji after point."
  (interactive)
  (emojify-delete-emoji (point)))

(defun emojify-delete-emoji-backward ()
  "Delete emoji before point."
  (interactive)
  (emojify-delete-emoji (1- (point))))

;; Integrate with delete-selection-mode
;; Basically instruct delete-selection mode to override our commands
;; if the region is active.
(put 'emojify-delete-emoji-forward 'delete-selection 'supersede)
(put 'emojify-delete-emoji-backward 'delete-selection 'supersede)



;; Updating background color on selection

(defun emojify--update-emojis-background-in-region (&optional beg end)
  "Update the background color for emojis between BEG and END."
  (when (equal emojify-display-style 'image)
    (emojify-with-saved-buffer-state
      (let ((emojify-region-beg (when (region-active-p) (region-beginning)))
            (emojify-region-end (when (region-active-p) (region-end))))
        (emojify-do-for-emojis-in-region beg end
          (plist-put (cdr (get-text-property emoji-start 'display))
                     :background
                     (emojify--get-image-background emoji-start
                                                    emoji-end)))))))

(defun emojify--update-emojis-background-in-region-starting-at (point)
  "Update background color for emojis in buffer starting at POINT.

This updates the emojis in the region starting from POINT, the end of region is
determined by product of `frame-height' and `frame-width' which roughly
corresponds to the visible area.  POINT usually corresponds to the starting
position of the window, see
`emojify-update-visible-emojis-background-after-command' and
`emojify-update-visible-emojis-background-after-window-scroll'

NOTE: `window-text-height' and `window-text-width' would have been more
appropriate here however they were not defined in Emacs v24.3 and below."
  (let* ((region-beginning point)
         (region-end (min (+ region-beginning (* (frame-height)
                                                 (frame-width)))
                          (point-max))))
    (emojify--update-emojis-background-in-region region-beginning
                                                 region-end)))

(defun emojify-update-visible-emojis-background-after-command ()
  "Function added to `post-command-hook' when region is active.

This function updates the backgrounds of the emojis in the region changed after
the command.

Ideally this would have been good enough to update emoji backgounds after region
changes, unfortunately this does not work well with commands that scroll the
window specifically `window-start' and `window-end' (sometimes only `window-end')
report incorrect values.

To work around this
`emojify-update-visible-emojis-background-after-window-scroll' is added to
`window-scroll-functions' to update emojis on window scroll."
  (emojify--update-emojis-background-in-region-starting-at (window-start)))

(defun emojify-update-visible-emojis-background-after-window-scroll (_window display-start)
  "Function added to `window-scroll-functions' when region is active.

This function updates the backgrounds of the emojis in the newly displayed area
of the window.  DISPLAY-START corresponds to the new start of the window."
  (emojify--update-emojis-background-in-region-starting-at display-start))



;; Lazy image downloading

(defvar emojify--refused-image-download-p nil
  "Used to remember that user has refused to download images in this session.")
(defvar emojify--download-in-progress-p nil
  "Is emoji download in progress used to avoid multiple emoji download prompts.")

(defun emojify--emoji-download-emoji-set (data)
  "Download the emoji images according to DATA."
  (let ((destination (make-temp-name temporary-file-directory)))
    (url-copy-file (ht-get data "url")
                   destination)
    (let ((downloaded-sha (with-temp-buffer
                            (insert-file-contents-literally destination)
                            (secure-hash 'sha256 (current-buffer)))))
      (when (string= downloaded-sha (ht-get data "sha256"))
        destination))))

(defun emojify--extract-emojis (file)
  "Extract the tar FILE in emoji directory."
  (let* ((default-directory emojify-emojis-dir))
    (with-temp-buffer
      (insert-file-contents-literally file)
      (let ((emojify-inhibit-emojify-in-current-buffer-p t))
        (tar-mode))
      (tar-untar-buffer))))

(defun emojify-download-emoji (emoji-set)
  "Download the provided EMOJI-SET."
  (interactive (list (completing-read "Select the emoji set you want to download: "
                                      (ht-keys emojify-emoji-set-json))))
  (let ((emoji-data (ht-get emojify-emoji-set-json emoji-set)))
    (cond ((not emoji-data)
           (error "No emoji set named %s found" emoji-set))
          ((and (file-exists-p (expand-file-name emoji-set emojify-emojis-dir))
                (called-interactively-p 'any))
           (message "%s emoji-set already downloaded, not downloading again!" emoji-set))
          (t
           (emojify--extract-emojis (emojify--emoji-download-emoji-set (ht-get emojify-emoji-set-json emoji-set)))))))

(defun emojify-download-emoji-maybe ()
  "Download emoji images if needed."
  (when (and (equal emojify-display-style 'image)
             (not (file-exists-p emojify-image-dir))
             (not emojify--refused-image-download-p))
    (unwind-protect
        ;; Do not prompt for download if download is in progress
        (unless emojify--download-in-progress-p
          (setq emojify--download-in-progress-p t)
          (if (yes-or-no-p "[emojify] Emoji images not available should I download them now?")
              (emojify-download-emoji emojify-emoji-set)
            ;; Remember that user has refused to download the emojis so that we
            ;; do not ask again in present session
            (setq emojify--refused-image-download-p t)
            (warn "[emojify] Not downloading emoji images for now. Emojis would
not be displayed since images are not available. If you wish to download emojis,
run the command `emojify-download-emoji'")))
      (setq emojify--download-in-progress-p nil))))

(defun emojify-ensure-images ()
  "Ensure that emoji images are downloaded."
  (if after-init-time
      (emojify-download-emoji-maybe)
    (add-hook 'after-init-hook #'emojify-download-emoji-maybe t)))



(defun emojify-turn-on-emojify-mode ()
  "Turn on `emojify-mode' in current buffer."

  ;; Calculate emoji data if needed
  (unless emojify-emojis
    (emojify-set-emoji-data))

  (when (emojify-buffer-p (current-buffer))
    ;; Download images if not available
    (emojify-ensure-images)

    ;; Install our jit-lock function
    (jit-lock-register #'emojify-redisplay-emojis-in-region)
    (add-hook 'jit-lock-after-change-extend-region-functions #'emojify-after-change-extend-region-function t t)

    ;; Update emoji backgrounds after each command
    (add-hook 'post-command-hook #'emojify-update-visible-emojis-background-after-command t t)

    ;; Update emoji backgrounds after mark is deactivated, this is needed since
    ;; deactivation can happen outside the command loop
    (add-hook 'deactivate-mark-hook #'emojify-update-visible-emojis-background-after-command t t)

    ;; Update emoji backgrounds after when window scrolls
    (add-hook 'window-scroll-functions #'emojify-update-visible-emojis-background-after-window-scroll t t)

    ;; Redisplay visible emojis when emoji style changes
    (add-hook 'emojify-emoji-style-change-hooks #'emojify-redisplay-emojis-in-region)))

(defun emojify-turn-off-emojify-mode ()
  "Turn off `emojify-mode' in current buffer."
  ;; Remove currently displayed emojis
  (save-restriction
    (widen)
    (emojify-undisplay-emojis-in-region (point-min) (point-max)))

  ;; Uninstall our jit-lock function
  (jit-lock-unregister #'emojify-redisplay-emojis-in-region)
  (remove-hook 'jit-lock-after-change-extend-region-functions #'emojify-after-change-extend-region-function t)

  ;; Disable hooks to update emoji backgrounds
  (remove-hook 'post-command-hook #'emojify-update-visible-emojis-background-after-command t)
  (remove-hook 'deactivate-mark-hook #'emojify-update-visible-emojis-background-after-command t)
  (remove-hook 'window-scroll-functions #'emojify-update-visible-emojis-background-after-window-scroll t)

  ;; Remove style change hooks
  (remove-hook 'emojify-emoji-style-change-hooks #'emojify-redisplay-emojis-in-region))

;;;###autoload
(define-minor-mode emojify-mode
  "Emojify mode"
  :init-value nil
  (if emojify-mode
      ;; Turn on
      (emojify-turn-on-emojify-mode)
    ;; Turn off
    (emojify-turn-off-emojify-mode)))

;;;###autoload
(define-globalized-minor-mode global-emojify-mode
  emojify-mode emojify-mode
  :init-value nil)

(defadvice mouse--drag-set-mark-and-point (after emojify-update-emoji-background (&rest ignored))
  "Advice to update emoji backgrounds after selection is changed using mouse.

Currently there are no hooks run after mouse movements, as such the emoji
backgrounds are updated only after the mouse button is released.  This advices
`mouse--drag-set-mark-and-point' which is run after selection changes to trigger
an update of emoji backgrounds.  Not the cleanest but the only way I can think of."
  (when emojify-mode
    (emojify-update-visible-emojis-background-after-command)))

(ad-activate #'mouse--drag-set-mark-and-point)

(defadvice isearch-repeat (around emojify-redisplay-after-isearch-left (direction))
  "Advice `isearch-repeat' to run emojify's point motion hooks.

By default isearch disables point-motion hooks while repeating (see
`isearch-invisible') breaking emojify's uncovering logic, this advice explicitly
runs (only emojify's) point motion hooks."
  (let ((old-pos (point)))
    (prog1 ad-do-it
      (when emojify-mode
        (let ((old-pos-props (text-properties-at old-pos))
              (new-pos-props (text-properties-at (point))))
          (unless (equal old-pos (point))
            (when (and (plist-get old-pos-props 'emojified)
                       (plist-get old-pos-props 'point-left))
              (funcall (plist-get old-pos-props 'point-left) old-pos (point)))
            (when (and (plist-get new-pos-props 'emojified)
                       (plist-get new-pos-props 'point-entered))
              (funcall (plist-get new-pos-props 'point-entered) old-pos (point)))))))))


(ad-activate #'isearch-repeat)

(defadvice text-scale-increase (after emojify-resize-emojis (&rest ignored))
  "Advice `text-scale-increase' to resize emojis on text resize."
  (when emojify-mode
    (let ((new-font-height (emojify-default-font-height)))
      (emojify-do-for-emojis-in-region (point-min) (point-max)
        (plist-put (cdr (get-text-property emoji-start 'display))
                   :height
                   new-font-height)))))

(ad-activate #'text-scale-increase)

(provide 'emojify)
;;; emojify.el ends here
