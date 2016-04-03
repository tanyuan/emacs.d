;; init.el
;; 
;; Emacs config file by tanyuan
;;  _                                      
;; | |_ __ _ _ __  _   _ _   _  __ _ _ __  
;; | __/ _` | '_ \| | | | | | |/ _` | '_ \ 
;; | || (_| | | | | |_| | |_| | (_| | | | |
;;  \__\__,_|_| |_|\__, |\__,_|\__,_|_| |_|
;;                 |___/                   

(add-to-list 'load-path "~/.emacs.d/modes")

(require 'package)
;; Add org package
(add-to-list 'package-archives '("org" . "http://orgmode.org/elpa/") t)
;; Add third-party MELPA packages
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/"))
(when (< emacs-major-version 24)
  ;; For important compatibility libraries like cl-lib
  (add-to-list 'package-archives '("gnu" . "http://elpa.gnu.org/packages/")))
(package-initialize)

;; Setup English and Chinese font
(set-frame-font "Source Code Pro")
(set-fontset-font "fontset-default" 'han '("Source Han Sans TC Medium"))

;; Set window title: Emacs - buffer
(setq-default frame-title-format '("Emacs - %b"))

;; Disable Startup screen
(setq inhibit-startup-message t) 

;; UI 
(menu-bar-mode t)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(set-fringe-mode 1) ;; diff-hl use the fringe

;; Dark theme
;(load-theme 'minimal t)
;; Light theme
(load-theme 'minimal-light t)
;; Alias for M-x for easier access
(global-set-key (kbd "C-x C-m") 'execute-extended-command)

;; I don't want to use arrow keys
(global-set-key (kbd "C-x h") 'previous-buffer)
(global-set-key (kbd "C-x l") 'next-buffer)

;; Kill buffer fast
(global-set-key (kbd "C-x C-k") 'kill-this-buffer)

;; Open default shell
(global-set-key (kbd "C-x C-t") 'shell)

;; Save autosave files (#*#) here instead of sitting beside the file
(setq auto-save-list-file-prefix
      (concat user-emacs-directory "auto-save-list/.saves-"))
;; Save backup files (*~) here instead of sitting beside the file
(setq backup-directory-alist
      `((".*" . ,(concat user-emacs-directory "backup"))))

;; Save place
(require 'saveplace)
(setq-default save-place t)
(setq save-place-file "~/.emacs.d/saved-places")
(setq save-place-forget-unreadable-files nil)

;; Scroll one line at a time (less "jumpy" than defaults)
(setq mouse-wheel-scroll-amount '(1 ((shift) . 1))) ;; one line at a time
(setq mouse-wheel-progressive-speed nil) ;; don't accelerate scrolling
(setq mouse-wheel-follow-mouse 't) ;; scroll window under mouse
(setq scroll-step 1) ;; keyboard scroll one line at a time

;; Enable Nyan Mode in the mode line
(require 'nyan-mode)
(nyan-mode 1)

;; Display emoji like :smile:
(global-emojify-mode 1)

;; Highlight matching  parentheses
(show-paren-mode 1)

;; Wrap lines by words
(global-visual-line-mode)

;; Show git diff status on the fringe
(require 'diff-hl)
(global-diff-hl-mode)

;; Start rainbow-delimiters (color parentheses) in most programming modes
(add-hook 'prog-mode-hook #'rainbow-delimiters-mode)

;; Dired+: show file details like Dired (should put before loading dired+.el)
(setq diredp-hide-details-initially-flag nil)
;; Disable Dired+ terrible colors
(setq font-lock-maximum-decoration (quote ((dired-mode . 1) (t . t))))

(require 'dired+)
(require 'dired-x)
;; Human readable size and sort folders first
(setq dired-listing-switches "-alh --group-directories-first")
(add-hook 'dired-mode-hook
	  (lambda ()
	  ;; Highlight current line
	  (hl-line-mode)
          ;; Hide hidden files in dired, toggle with C-x M-o
          (dired-omit-mode)
          ;; Show git diff status on the fring
          (diff-hl-dired-mode)
          ))
(setq dired-omit-files "^\\...+$")

;; Open git status
(require 'magit)
(global-set-key (kbd "C-c g") 'magit-status)

;; org: I use Tab for evil mode so I am unable to trigger <s<Tab> template
(defun org-insert-src-block ()
  "Insert source code block in org-mode."
  (interactive
  (progn
    (insert "#+BEGIN_SRC\n")
    (newline-and-indent)
    (insert "#+END_SRC\n")
    (previous-line 2))
))

(require 'org)
;; Org: drag and drop images to org mode
(require 'org-download)
(setq org-modules '(org-mouse))
(setq org-startup-indented t)
(add-hook 'org-mode-hook
	  (lambda ()
	  (local-set-key (kbd "C-c n") 'org-narrow-to-subtree)
	  (local-set-key (kbd "C-c w") 'widen)
	  (local-set-key (kbd "C-c b") 'org-tree-to-indirect-buffer)
	  (local-set-key (kbd "C-c i") 'org-toggle-inline-images)
	  (local-set-key (kbd "C-c s") 'org-download-screenshot)
	  (local-set-key (kbd "C-c y") 'org-download-yank)
	  (local-set-key (kbd "C-c d") 'org-download-delete)
	  (local-set-key (kbd "C-c a") 'org-insert-src-block)
          ))
;; Org set image size if not specified
;;   #+ATTR_ORG: :width 100
(setq org-image-actual-width '(480))
;; Org capture (jot down notes quickly)
(global-set-key (kbd "C-c c") 'org-capture)
(setq org-default-notes-file "~/org/capture.org")
(setq org-capture-templates
      '(("t" "Todo" entry (file+headline org-default-notes-file "Tasks")
             "* TODO %?  %i\n  %T")
        ("i" "Idea" entry (file+headline org-default-notes-file "Ideas")
             "* %?  %i\n  %T")))

;; Enable PDF Tools
(pdf-tools-install)
(add-to-list 'org-file-apps '("\\.pdf\\'" . org-pdfview-open))
(add-to-list 'org-file-apps '("\\.pdf::\\([[:digit:]]+\\)\\'" . org-pdfview-open))

;; Evil mode (Vim-like key bindings)
(require 'evil)
(evil-mode 1)
;; Still use Emacs as default, C-z to toggle Evil mode
;(setq evil-default-state 'emacs)
;; Map j/k to gj/gk
(define-key evil-normal-state-map (kbd "j") 'evil-next-visual-line)
(define-key evil-normal-state-map (kbd "k") 'evil-previous-visual-line)
;; Map Tab to Escape
(define-key evil-normal-state-map (kbd "TAB") 'evil-force-normal-state)
(define-key evil-visual-state-map (kbd "TAB") 'evil-change-to-previous-state)
(define-key evil-insert-state-map (kbd "TAB") 'evil-normal-state)
(define-key evil-replace-state-map (kbd "TAB") 'evil-normal-state)

;; Make Evil work for org mode!
(require 'evil-org)
;; Make Evil work for magit!
(require 'evil-magit)

;; Overwrite default buffer manager to ibuffer
(require 'ibuffer)
;; Start ibuffer in Evil mode, otherwise it goes to Emacs mode
(evil-set-initial-state 'ibuffer-mode 'normal)
(global-set-key (kbd "C-x C-b") 'ibuffer)
(add-hook 'ibuffer-mode-hook
	  (lambda ()
	  ;; Highlight current line
	  (hl-line-mode)
	  ))

;; Better fcitx input method integration with Evil mode
(require 'fcitx)
;; Toggle fcitx also when enter/exit Insert mode
(fcitx-evil-turn-on)
;; Toggle fcitx on common Emacs commands
(fcitx-M-x-turn-on)
(fcitx-shell-command-turn-on)
(fcitx-eval-expression-turn-on)

;; Startup with dired
(dired "~")
