;;; init.el --- Emacs config file

;; by tanyuan, 2016
;;  _                                      
;; | |_ __ _ _ __  _   _ _   _  __ _ _ __  
;; | __/ _` | '_ \| | | | | | |/ _` | '_ \ 
;; | || (_| | | | | |_| | |_| | (_| | | | |
;;  \__\__,_|_| |_|\__, |\__,_|\__,_|_| |_|
;;                 |___/                   

;; Custom files, not installed with package managers
(add-to-list 'load-path (concat user-emacs-directory "modes"))
(add-to-list 'custom-theme-load-path (concat user-emacs-directory "themes"))

;; Setup themes
(setq dark-theme 'minimal)
(setq light-theme 'minimal-light)

;; Default theme
(setq dark-or-light 'light)
(load-theme light-theme t)

;; Toggle dark & light themes with shortcut
(defun toggle-dark-light-theme ()
  (interactive)
  (if (eq dark-or-light 'light)
      (progn
	(setq dark-or-light 'dark)
	(load-theme dark-theme t))
      (progn
	(setq dark-or-light 'light)
	(load-theme light-theme t))
      )
    )
(global-set-key (kbd "C-c t") 'toggle-dark-light-theme)

(require 'package)
;; Add org package
(add-to-list 'package-archives '("org" . "http://orgmode.org/elpa/") t)
;; Add third-party MELPA packages
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/"))
(when (< emacs-major-version 24)
  ;; For important compatibility libraries like cl-lib
  (add-to-list 'package-archives '("gnu" . "http://elpa.gnu.org/packages/")))
(package-initialize)

;; Save backup files (*~) here instead of sitting beside the file
(setq backup-directory-alist
      `((".*" . ,(concat user-emacs-directory "backup"))))

;; Save place
(require 'saveplace)
(setq-default save-place t)
(setq save-place-file (concat user-emacs-directory "saved-places"))
(setq save-place-forget-unreadable-files nil)

;; Set window title: Emacs - buffer
(setq-default frame-title-format '("Emacs - %b -%m"))

;; Setup English and Chinese font
(set-frame-font "Source Code Pro")
(set-fontset-font "fontset-default" 'han '("Source Han Sans TC Medium"))

;; Disable Startup screen
(setq inhibit-startup-message t) 

;; UI 
(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(set-fringe-mode 1) ;; diff-hl use the fringe

;; Wind Move: move between windows
(when (fboundp 'windmove-default-keybindings)
  (windmove-default-keybindings))
(global-set-key (kbd "C-x <left>")  'windmove-left)
(global-set-key (kbd "C-x <right>") 'windmove-right)
(global-set-key (kbd "C-x <up>")    'windmove-up)
(global-set-key (kbd "C-x <down>")  'windmove-down)
(global-set-key (kbd "C-x h")  'windmove-left)
(global-set-key (kbd "C-x l") 'windmove-right)
(global-set-key (kbd "C-x k")    'windmove-up)
(global-set-key (kbd "C-x j")  'windmove-down)

;; Alias for M-x for easier access
(global-set-key (kbd "C-x C-m") 'execute-extended-command)

;; Kill buffer fast
(global-set-key (kbd "C-x C-k") 'kill-this-buffer)

;; Toggle comment a region
(global-set-key (kbd "C-x ;") 'comment-or-uncomment-region)

;; Open default shell
(global-set-key (kbd "C-x C-t") 'shell)

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
;; Auto-complete round (), curly {}, square []
(add-hook 'prog-mode-hook #'paredit-mode)

;; Dired+: show file details like Dired (should put before loading dired+.el)
(setq diredp-hide-details-initially-flag nil)
;; Disable Dired+ terrible colors
(setq font-lock-maximum-decoration (quote ((dired-mode . 1) (t . t))))

(require 'dired+)
(require 'dired-x)
;; Human readable size and sort folders first
;(setq dired-listing-switches "-alh --group-directories-first")
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
(global-set-key (kbd "C-x g") 'magit-status)

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
	  (local-set-key (kbd "C-c 8") 'org-ctrl-c-star)
          ))
;; Disable code highlighting so we can have our own background color
;;   use C-c ' to enter code major mode
(setq org-src-fontify-natively nil)
;; Org set image size if not specified
;;   #+ATTR_ORG: :width 100
(setq org-image-actual-width '(480))
;; Org capture (jot down notes quickly)
(global-set-key (kbd "C-c l") 'org-store-link)
(global-set-key (kbd "C-c c") 'org-capture)
(setq org-default-notes-file "~/org/capture.org")
(setq org-capture-templates
      '(("t" "Todo" entry (file+headline org-default-notes-file "Tasks")
             "* TODO %?  %i\n  %T")
        ("i" "Idea" entry (file+headline org-default-notes-file "Ideas")
             "* %?  %i\n  %T")))

;; Evil mode (Vim-like key bindings)
(require 'evil)
(evil-mode 1)
;; Still use Emacs as default, C-z to toggle Evil mode
;(setq evil-default-state 'emacs)
;; Map j/k to gj/gk
(define-key evil-normal-state-map (kbd "j") 'evil-next-visual-line)
(define-key evil-normal-state-map (kbd "k") 'evil-previous-visual-line)

;; The following configs try to use J, K as arrow keys as in Evil:

;; Make Evil work for org mode!
(require 'evil-org)
;; Make Evil work for magit!
(require 'evil-magit)

;; Overwrite default buffer manager to ibuffer
(require 'ibuffer)
(global-set-key (kbd "C-x C-b") 'ibuffer)
(setq ibuffer-default-sorting-mode 'major-mode)
;; Hide Emacs created buffers that starts with *
(require 'ibuf-ext)
(add-to-list 'ibuffer-never-show-predicates "^\\*")
;; Custom groups
(setq ibuffer-saved-filter-groups
	(quote (("default"
		("Org" (mode . org-mode))  
		("Dired" (mode . dired-mode))
		))))
(add-hook 'ibuffer-mode-hook
	  (lambda ()
	  ;; Highlight current line
	  (hl-line-mode)
	  ;; Enable custom grouping
	  (ibuffer-switch-to-saved-filter-groups "default")
	  ))
;; Start ibuffer in Evil mode, otherwise it goes to Emacs mode
(evil-set-initial-state 'ibuffer-mode 'normal)

;; Package: package-list-packages
(add-hook 'package-menu-mode-hook
	  (lambda ()
	  (hl-line-mode)
	  (local-set-key (kbd "j") 'next-line)
	  (local-set-key (kbd "k") 'previous-line)
          ))

;; Bookmark: list bookmarks
(global-set-key (kbd "C-x m") 'bookmark-bmenu-list)
(add-hook 'bookmark-bmenu-mode-hook
	  (lambda ()
	  (hl-line-mode)
	  (local-set-key (kbd "j") 'next-line)
	  (local-set-key (kbd "k") 'previous-line)
          ))

;; For GNU/Linux
(when (eq system-type 'gnu/linux)
    ;; Enable PDF Tools
    (pdf-tools-install)
    ;(add-to-list 'org-file-apps '("\\.pdf\\'" . org-pdfview-open))
    ;(add-to-list 'org-file-apps '("\\.pdf::\\([[:digit:]]+\\)\\'" . org-pdfview-open))

    ;; Org: Open PDFs in external viewer: evince
    (add-to-list 'org-file-apps '("\\.pdf\\'" . "evince %s"))
    (add-to-list 'org-file-apps '("\\.pdf::\\([[:digit:]]+\\)\\'" . "evince -p %1 %s"))

    ;; Better fcitx input method integration with Evil mode
    (require 'fcitx)
    ;; Toggle fcitx also when enter/exit Insert mode
    (fcitx-evil-turn-on)
    ;; Toggle fcitx on common Emacs commands
    (fcitx-M-x-turn-on)
    (fcitx-shell-command-turn-on)
    (fcitx-eval-expression-turn-on)
)

;; For Mac OS X
(when (eq system-type 'darwin)
    ;; Menu bar blends well on Mac OS X
    (menu-bar-mode t)
    ;; default font size (point * 10)
    (set-face-attribute 'default nil :height 180)
)

;; Startup with dired
(dired "~")
