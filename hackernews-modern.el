;;; hackernews-modern.el --- Hacker News client with modern widget UI -*- lexical-binding: t -*-

;; Copyright (C) 2012-2025 The Hackernews.el Authors

;; Author: Lincoln de Sousa <lincoln@clarete.li>
;; Keywords: comm hypermedia news
;; Version: 0.9.0
;; Package-Requires: ((emacs "28.1") (visual-fill-column "2.2"))
;; URL: https://git.andros.dev/andros/hackernews-modern.el

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Read Hacker News from Emacs using a modern widget-based interface.
;; Fork of https://github.com/clarete/hackernews.el

;;; Code:

(require 'browse-url)
(require 'cus-edit)
(require 'format-spec)
(require 'url)
(require 'widget)
(require 'wid-edit)
(require 'cl-lib)

;; Forward declarations for controller symbols referenced in view.
(defvar hackernews-mode-map)
(defvar hackernews-preserve-point)
(declare-function visual-fill-column-mode "visual-fill-column")

;;;; MODEL ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;; Customization

(defgroup hackernews nil
  "Hacker News client with modern widget UI."
  :group 'external
  :prefix "hackernews-")

(defcustom hackernews-items-per-page 20
  "Default number of stories to retrieve in one go."
  :package-version '(hackernews . "0.4.0")
  :type 'integer)

(defcustom hackernews-default-feed "top"
  "Default story feed to load.
See `hackernews-feed-names' for supported feed types."
  :package-version '(hackernews . "0.4.0")
  :type '(choice (const :tag "Top stories"  "top")
                 (const :tag "New stories"  "new")
                 (const :tag "Best stories" "best")
                 (const :tag "Ask stories"  "ask")
                 (const :tag "Show stories" "show")
                 (const :tag "Job stories"  "job")))

(defcustom hackernews-suppress-url-status t
  "Whether to suppress messages controlled by `url-show-status'.
When nil, `url-show-status' determines whether certain status
messages are displayed when retrieving online data.  This is
suppressed by default so that the hackernews progress reporter is
not interrupted."
  :package-version '(hackernews . "0.4.0")
  :type 'boolean)

;;;;; Constants

(defconst hackernews-api-version "v0"
  "Currently supported version of the Hacker News API.")

(defconst hackernews-api-format
  (format "https://hacker-news.firebaseio.com/%s/%%s.json"
          hackernews-api-version)
  "Format of targeted Hacker News API URLs.")

(defconst hackernews-site-item-format "https://news.ycombinator.com/item?id=%s"
  "Format of Hacker News website item URLs.")

(defvar hackernews-feed-names
  '(("top"  . "top stories")
    ("new"  . "new stories")
    ("best" . "best stories")
    ("ask"  . "ask stories")
    ("show" . "show stories")
    ("job"  . "job stories"))
  "Map feed types as strings to their display names.")
(put 'hackernews-feed-names 'risky-local-variable t)

(defvar hackernews-feed-history ()
  "Completion history of hackernews feeds switched to.")

;;;;; Buffer-local state

(defvar hackernews--feed-state ()
  "Plist capturing state of current buffer's Hacker News feed.
:feed     - Type of endpoint feed; see `hackernews-feed-names'.
:items    - Vector holding items being or last fetched.
:register - Cons of number of items currently displayed and
            vector of item IDs last read from this feed.
            The `car' is thus an offset into the `cdr'.")
(make-variable-buffer-local 'hackernews--feed-state)

(defun hackernews--get (prop)
  "Extract value of PROP from `hackernews--feed-state'."
  (plist-get hackernews--feed-state prop))

(defun hackernews--put (prop val)
  "Change value in `hackernews--feed-state' of PROP to VAL."
  (setq hackernews--feed-state (plist-put hackernews--feed-state prop val)))

;;;;; URL helpers

(defun hackernews--comments-url (id)
  "Return Hacker News website URL for item with ID."
  (format hackernews-site-item-format id))

(defun hackernews--format-api-url (fmt &rest args)
  "Construct a Hacker News API URL.
The result of passing FMT and ARGS to `format' is substituted in
`hackernews-api-format'."
  (format hackernews-api-format (apply #'format fmt args)))

(defun hackernews--item-url (id)
  "Return Hacker News API URL for item with ID."
  (hackernews--format-api-url "item/%s" id))

(defun hackernews--feed-url (feed)
  "Return Hacker News API URL for FEED.
See `hackernews-feed-names' for supported values of FEED."
  (hackernews--format-api-url "%sstories" feed))

(defun hackernews--feed-name (feed)
  "Lookup FEED in `hackernews-feed-names'."
  (cdr (assoc-string feed hackernews-feed-names)))

(defun hackernews--feed-annotation (feed)
  "Annotate FEED during completion.
This is intended as an :annotation-function in
`completion-extra-properties'."
  (let ((name (hackernews--feed-name feed)))
    (and name (concat " - " name))))

;;;;; HTTP and JSON

(defun hackernews--read-contents (url)
  "Retrieve URL and return its contents parsed as a JSON alist."
  (with-temp-buffer
    (let ((url-show-status (unless hackernews-suppress-url-status
                             url-show-status)))
      (url-insert-file-contents url)
      (json-parse-buffer :object-type 'alist))))

(defun hackernews--retrieve-items ()
  "Retrieve items associated with current buffer."
  (let* ((items  (hackernews--get :items))
         (reg    (hackernews--get :register))
         (nitem  (length items))
         (offset (car reg))
         (ids    (cdr reg)))
    (dotimes-with-progress-reporter (i nitem)
        (format "Retrieving %d %s..."
                nitem (hackernews--feed-name (hackernews--get :feed)))
      (aset items i (hackernews--read-contents
                     (hackernews--item-url (aref ids (+ offset i))))))))

;;;; VIEW ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;; Faces

(defface hackernews-link
  '((t :inherit link :underline nil))
  "Face used for story title links."
  :package-version '(hackernews . "0.4.0"))

(defface hackernews-comment-count
  '((t :inherit hackernews-link))
  "Face used for comment counts."
  :package-version '(hackernews . "0.4.0"))

(defface hackernews-score
  '((t :inherit default))
  "Face used for the score of a story."
  :package-version '(hackernews . "0.4.0"))

(defface hackernews-logo
  '((t :foreground "#ff6600" :height 1.5))
  "Face used for the \"Y\" in the Hacker News logo."
  :package-version '(hackernews . "0.8.0"))

(defface hackernews-title-text
  '((t :foreground "#ff6600" :height 1.3))
  "Face used for the \"Hacker News\" title text."
  :package-version '(hackernews . "0.8.0"))

(defface hackernews-separator
  '((t :foreground "#666666"))
  "Face used for horizontal separator lines."
  :package-version '(hackernews . "0.8.0"))

(defface hackernews-score-modern
  '((t :foreground "#ff6600"))
  "Face used for story scores."
  :package-version '(hackernews . "0.8.0"))

(defface hackernews-author
  '((t :foreground "#0066cc"))
  "Face used for author names."
  :package-version '(hackernews . "0.8.0"))

(defface hackernews-feed-indicator
  '((t :foreground "#ff6600"))
  "Face used for the current feed indicator."
  :package-version '(hackernews . "0.8.0"))

;;;;; Customization (visual)

(defcustom hackernews-display-width 80
  "Maximum width for displaying hackernews content."
  :package-version '(hackernews . "0.8.0")
  :type 'integer)

(defcustom hackernews-enable-emojis nil
  "Whether to display emojis in the interface.
When non-nil, feed navigation buttons and comment counts will
include emoji icons for visual enhancement."
  :package-version '(hackernews . "0.8.0")
  :type 'boolean)

(defcustom hackernews-before-render-hook ()
  "Hook called before rendering any new items."
  :package-version '(hackernews . "0.4.0")
  :type 'hook)

(defcustom hackernews-after-render-hook ()
  "Hook called after rendering any new items.
The position of point will not have been affected by the render."
  :package-version '(hackernews . "0.4.0")
  :type 'hook)

(defcustom hackernews-finalize-hook ()
  "Hook called as final step of loading any new items.
The position of point may have been adjusted after the render,
buffer-local feed state will have been updated and the hackernews
buffer will be current and displayed in the selected window."
  :package-version '(hackernews . "0.4.0")
  :type 'hook)

;;;;; UI helpers

(defconst hackernews--separator-char ?-
  "Character used for horizontal separators.")

(defun hackernews--string-separator ()
  "Return a separator string of `hackernews-display-width' dashes."
  (make-string hackernews-display-width hackernews--separator-char))

(defun hackernews--insert-separator ()
  "Insert a horizontal separator line."
  (insert "\n")
  (insert (propertize (hackernews--string-separator)
                      'face 'hackernews-separator))
  (insert "\n\n"))

(defun hackernews--insert-logo ()
  "Insert the Hacker News logo."
  (insert "\n")
  (insert (propertize "Y " 'face 'hackernews-logo))
  (insert (propertize "Hacker News" 'face 'hackernews-title-text))
  (insert "\n\n"))

(defconst hackernews--feed-buttons
  '(("top"  "🔥 " "View top stories"  hackernews-top-stories)
    ("new"  "🆕 " "View new stories"  hackernews-new-stories)
    ("best" "⭐ " "View best stories" hackernews-best-stories)
    ("ask"  "❓ " "View ask stories"  hackernews-ask-stories)
    ("show" "📺 " "View show stories" hackernews-show-stories))
  "Feed button specs: (feed-key emoji help-text command).")

(defun hackernews--insert-header (feed-name)
  "Insert the page header showing FEED-NAME and navigation buttons."
  (hackernews--insert-logo)
  (dolist (spec hackernews--feed-buttons)
    (let ((label (capitalize (nth 0 spec)))
          (emoji (nth 1 spec))
          (help  (nth 2 spec))
          (cmd   (nth 3 spec)))
      (widget-create 'push-button
                     :notify (lambda (&rest _) (call-interactively cmd))
                     :help-echo help
                     (format " %s%s " (if hackernews-enable-emojis emoji "") label))
      (insert " ")))
  (widget-create 'push-button
                 :notify (lambda (&rest _) (hackernews-reload))
                 :help-echo "Refresh current feed"
                 " ↻ Refresh ")
  (insert "\n\n")
  (insert (propertize (format "Showing: %s\n" feed-name)
                      'face 'hackernews-feed-indicator))
  (insert "Keyboard: (n) Next | (p) Previous | (g) Refresh | (q) Quit\n")
  (hackernews--insert-separator))

;;;;; Item rendering

(autoload 'xml-substitute-special "xml")

(defun hackernews--render-item (item)
  "Render Hacker News ITEM in the current buffer using widgets."
  (let* ((id           (cdr (assq 'id          item)))
         (title        (cdr (assq 'title       item)))
         (score        (cdr (assq 'score       item)))
         (by           (cdr (assq 'by          item)))
         (item-url     (cdr (assq 'url         item)))
         (descendants  (cdr (assq 'descendants item)))
         (comments-url (hackernews--comments-url id))
         (item-start   (point)))
    (setq title (xml-substitute-special title))
    (widget-create 'push-button
                   :notify (lambda (&rest _)
                             (browse-url (or item-url comments-url)))
                   :help-echo (or item-url "No URL")
                   :format "%[%v%]"
                   title)
    (insert "\n")
    (insert (propertize "  " 'face 'default))
    (insert (propertize (format "↑%d" (or score 0))
                        'face 'hackernews-score-modern))
    (insert " | ")
    (widget-create 'push-button
                   :notify (lambda (&rest _)
                             (browse-url comments-url))
                   :help-echo (format "View comments: %s" comments-url)
                   :format "%[%v%]"
                   (format "%s%d comment%s"
                           (if hackernews-enable-emojis "💬 " "")
                           (or descendants 0)
                           (if (= (or descendants 0) 1) "" "s")))
    (when by
      (insert " | by ")
      (insert (propertize by 'face 'hackernews-author)))
    (insert "\n")
    (hackernews--insert-separator)
    (put-text-property item-start (point) 'hackernews-item-id id)))

;;;;; Buffer display

(defun hackernews--display-items ()
  "Render items associated with the current buffer and display it."
  (let* ((reg        (hackernews--get :register))
         (items      (hackernews--get :items))
         (nitem      (length items))
         (feed       (hackernews--get :feed))
         (feed-name  (hackernews--feed-name feed))
         (first-load (= (buffer-size) 0))
         (inhibit-read-only t))
    (when first-load
      (hackernews--insert-header feed-name))
    (run-hooks 'hackernews-before-render-hook)
    (save-excursion
      (goto-char (point-max))
      (mapc #'hackernews--render-item
            (cl-remove-if (lambda (item)
                            (or (eq item :null)
                                (cdr (assq 'deleted item))
                                (cdr (assq 'dead item))))
                          items)))
    (run-hooks 'hackernews-after-render-hook)
    (use-local-map (make-composed-keymap (list widget-keymap hackernews-mode-map)
                                         special-mode-map))
    (widget-setup)
    (when (and (require 'visual-fill-column nil t)
               (boundp 'visual-fill-column-width))
      (setq-local visual-fill-column-width hackernews-display-width)
      (setq-local visual-fill-column-center-text t)
      (visual-fill-column-mode 1))
    (when (fboundp 'display-line-numbers-mode)
      (display-line-numbers-mode 0))
    (cond
     (first-load
      (goto-char (point-min))
      (widget-forward 1))
     ((not (or (<= nitem 0) hackernews-preserve-point))
      (goto-char (point-max))
      (hackernews-previous-item nitem)))
    (setcar reg (+ (car reg) nitem)))
  (read-only-mode 1)
  (pop-to-buffer (current-buffer) '((display-buffer-same-window)))
  (run-hooks 'hackernews-finalize-hook))

;;;; CONTROLLER ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;; Customization (behavioral)

(defcustom hackernews-preserve-point t
  "Whether to preserve point when loading more stories.
When nil, point is placed on first new item retrieved."
  :package-version '(hackernews . "0.4.0")
  :type 'boolean)

(defcustom hackernews-internal-browser-function
  (if (functionp 'eww-browse-url)
      #'eww-browse-url
    #'browse-url-text-emacs)
  "Function to load a given URL within Emacs.
See `browse-url-browser-function' for some possible options."
  :package-version '(hackernews . "0.4.0")
  :type (cons 'radio (butlast (cdr (custom-variable-type
                                    'browse-url-browser-function)))))

;;;;; Keymaps

(defvar hackernews-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "f" #'hackernews-switch-feed)
    (define-key map "g" #'hackernews-reload)
    (define-key map "m" #'hackernews-load-more-stories)
    (define-key map "n" #'hackernews-next-item)
    (define-key map "p" #'hackernews-previous-item)
    map)
  "Keymap used in hackernews buffer.")

;;;;; Major mode

(define-derived-mode hackernews-mode special-mode "HN"
  "Mode for browsing Hacker News.

Key bindings:
\\<hackernews-mode-map>
\\[hackernews-next-item]		Move to next story.
\\[hackernews-previous-item]		Move to previous story.
\\[hackernews-load-more-stories]	Load more stories.
\\[hackernews-reload]			Reload stories.
\\[hackernews-switch-feed]		Switch feed.
\\<special-mode-map>\\[quit-window]	Quit.

\\{hackernews-mode-map}"
  :interactive nil
  (setq hackernews--feed-state ())
  (setq truncate-lines t)
  (buffer-disable-undo))

;;;;; Navigation

(defun hackernews-next-item (&optional n)
  "Move to Nth next story (previous if N is negative).
N defaults to 1."
  (declare (modes hackernews-mode))
  (interactive "p")
  (let ((count (or n 1))
        (separator-regex (concat "^" (regexp-quote (hackernews--string-separator)) "$")))
    (if (< count 0)
        (hackernews-previous-item (- count))
      (dotimes (_ count)
        (if (search-forward-regexp separator-regex nil t)
            (progn
              (forward-line 2)
              (beginning-of-line)
              (recenter))
          (message "No more stories"))))))

(defun hackernews-previous-item (&optional n)
  "Move to Nth previous story (next if N is negative).
N defaults to 1."
  (declare (modes hackernews-mode))
  (interactive "p")
  (let ((count (or n 1))
        (separator-regex (concat "^" (regexp-quote (hackernews--string-separator)) "$")))
    (if (< count 0)
        (hackernews-next-item (- count))
      (dotimes (_ count)
        (search-backward-regexp separator-regex nil t)
        (if (search-backward-regexp separator-regex nil t)
            (progn
              (forward-line 2)
              (beginning-of-line)
              (recenter))
          (goto-char (point-min))
          (widget-forward 1))))))

(defun hackernews-first-item ()
  "Move point to the first story in the hackernews buffer."
  (declare (modes hackernews-mode))
  (interactive)
  (goto-char (point-min))
  (hackernews-next-item))

;;;;; Orchestration

(defun hackernews--load-stories (feed n &optional append)
  "Retrieve and render at most N items from FEED.
Create and setup corresponding hackernews buffer if necessary.

If APPEND is nil, refresh the list of items from FEED and render
at most N of its top items.  Any previous hackernews buffer
contents are overwritten.

Otherwise, APPEND should be a cons cell (OFFSET . IDS), where IDS
is the vector of item IDs corresponding to FEED and OFFSET
indicates where in IDS the previous retrieval and render left
off.  At most N of FEED's items starting at OFFSET are then
rendered at the end of the hackernews buffer."
  (let* ((name   (hackernews--feed-name feed))
         (offset (or (car append) 0))
         (ids    (if append
                     (cdr append)
                   (message "Retrieving %s..." name)
                   (hackernews--read-contents (hackernews--feed-url feed)))))
    (with-current-buffer (get-buffer-create (format "*hackernews %s*" name))
      (unless append
        (let ((inhibit-read-only t))
          (erase-buffer))
        (remove-overlays)
        (hackernews-mode))
      (hackernews--put :feed     feed)
      (hackernews--put :register (cons offset ids))
      (hackernews--put :items    (make-vector
                                  (max 0 (min (- (length ids) offset)
                                              (prefix-numeric-value
                                               (or n hackernews-items-per-page))))
                                  ()))
      (hackernews--retrieve-items)
      (hackernews--display-items))))

;;;;; Interactive commands

;;;###autoload
(defun hackernews (&optional n)
  "Read top N Hacker News stories.
The feed is determined by `hackernews-default-feed' and N defaults
to `hackernews-items-per-page'."
  (interactive "P")
  (hackernews--load-stories hackernews-default-feed n))

(defun hackernews-reload (&optional n)
  "Reload top N stories from the current feed.
N defaults to `hackernews-items-per-page'."
  (declare (modes hackernews-mode))
  (interactive "P")
  (unless (derived-mode-p #'hackernews-mode)
    (user-error "Not a hackernews buffer"))
  (hackernews--load-stories
   (or (hackernews--get :feed)
       (user-error "Buffer unassociated with feed"))
   n))

(defun hackernews-load-more-stories (&optional n)
  "Load N more stories into the hackernews buffer.
N defaults to `hackernews-items-per-page'."
  (declare (modes hackernews-mode))
  (interactive "P")
  (unless (derived-mode-p #'hackernews-mode)
    (user-error "Not a hackernews buffer"))
  (let ((feed (hackernews--get :feed))
        (reg  (hackernews--get :register)))
    (unless (and feed reg)
      (user-error "Buffer in invalid state"))
    (if (>= (car reg) (length (cdr reg)))
        (message "%s" (substitute-command-keys "\
End of feed; type \\[hackernews-reload] to load new items."))
      (hackernews--load-stories feed n reg))))

(defun hackernews-switch-feed (&optional n)
  "Read top N stories from a feed chosen with completion.
N defaults to `hackernews-items-per-page'."
  (interactive "P")
  (hackernews--load-stories
   (let ((completion-extra-properties
          (list :annotation-function #'hackernews--feed-annotation)))
     (completing-read
      (format-prompt "Hacker News feed" hackernews-default-feed)
      hackernews-feed-names nil t nil 'hackernews-feed-history
      hackernews-default-feed))
   n))

(defun hackernews-top-stories (&optional n)
  "Read top N Hacker News top stories.
N defaults to `hackernews-items-per-page'."
  (interactive "P")
  (hackernews--load-stories "top" n))

(defun hackernews-new-stories (&optional n)
  "Read top N Hacker News new stories.
N defaults to `hackernews-items-per-page'."
  (interactive "P")
  (hackernews--load-stories "new" n))

(defun hackernews-best-stories (&optional n)
  "Read top N Hacker News best stories.
N defaults to `hackernews-items-per-page'."
  (interactive "P")
  (hackernews--load-stories "best" n))

(defun hackernews-ask-stories (&optional n)
  "Read top N Hacker News ask stories.
N defaults to `hackernews-items-per-page'."
  (interactive "P")
  (hackernews--load-stories "ask" n))

(defun hackernews-show-stories (&optional n)
  "Read top N Hacker News show stories.
N defaults to `hackernews-items-per-page'."
  (interactive "P")
  (hackernews--load-stories "show" n))

(defun hackernews-job-stories (&optional n)
  "Read top N Hacker News job stories.
N defaults to `hackernews-items-per-page'."
  (interactive "P")
  (hackernews--load-stories "job" n))

(provide 'hackernews-modern)

;;; hackernews-modern.el ends here
