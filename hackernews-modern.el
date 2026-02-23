;;; hackernews-modern.el --- Hacker News client with modern widget UI -*- lexical-binding: t -*-

;; Copyright (C) 2012-2025 The Hackernews.el Authors

;; Author: Lincoln de Sousa <lincoln@clarete.li>
;; Keywords: comm hypermedia news
;; Version: 0.9.0
;; Package-Requires: ((emacs "28.1") (visual-fill-column "2.2"))
;; URL: https://git.andros.dev/andros/hackernews-modern-el

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
(require 'json)
(require 'widget)
(require 'wid-edit)
(require 'cl-lib)
(require 'hackernews-modern-queue)

;; Forward declarations for controller symbols referenced in view.
(defvar hackernews-modern-mode-map)
(defvar hackernews-modern-preserve-point)
(declare-function visual-fill-column-mode "visual-fill-column")

;;;; MODEL ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;; Customization

(defgroup hackernews-modern nil
  "Hacker News client with modern widget UI."
  :group 'external
  :prefix "hackernews-modern-")

(defcustom hackernews-modern-items-per-page 20
  "Default number of stories to retrieve in one go."
  :package-version '(hackernews-modern . "0.4.0")
  :type 'integer)

(defcustom hackernews-modern-default-feed "top"
  "Default story feed to load.
See `hackernews-modern-feed-names' for supported feed types."
  :package-version '(hackernews-modern . "0.4.0")
  :type '(choice (const :tag "Top stories"  "top")
                 (const :tag "New stories"  "new")
                 (const :tag "Best stories" "best")
                 (const :tag "Ask stories"  "ask")
                 (const :tag "Show stories" "show")
                 (const :tag "Job stories"  "job")))

(defcustom hackernews-modern-suppress-url-status t
  "Whether to suppress messages controlled by `url-show-status'.
When nil, `url-show-status' determines whether certain status
messages are displayed when retrieving online data.  This is
suppressed by default so that the hackernews-modern progress reporter is
not interrupted."
  :package-version '(hackernews-modern . "0.4.0")
  :type 'boolean)

;;;;; Constants

(defconst hackernews-modern-api-version "v0"
  "Currently supported version of the Hacker News API.")

(defconst hackernews-modern-api-format
  (format "https://hacker-news.firebaseio.com/%s/%%s.json"
          hackernews-modern-api-version)
  "Format of targeted Hacker News API URLs.")

(defconst hackernews-modern-site-item-format "https://news.ycombinator.com/item?id=%s"
  "Format of Hacker News website item URLs.")

(defvar hackernews-modern-feed-names
  '(("top"  . "top stories")
    ("new"  . "new stories")
    ("best" . "best stories")
    ("ask"  . "ask stories")
    ("show" . "show stories")
    ("job"  . "job stories"))
  "Map feed types as strings to their display names.")
(put 'hackernews-modern-feed-names 'risky-local-variable t)

(defvar hackernews-modern-feed-history ()
  "Completion history of hackernews-modern feeds switched to.")

;;;;; Buffer-local state

(defvar-local hackernews-modern--feed-state ()
  "Plist capturing state of current buffer's Hacker News feed.
:feed     - Type of endpoint feed; see `hackernews-modern-feed-names'.
:items    - Vector holding items being or last fetched.
:register - Cons of number of items currently displayed and
            vector of item IDs last read from this feed.
            The `car' is thus an offset into the `cdr'.")

(defun hackernews-modern--get (prop)
  "Extract value of PROP from `hackernews-modern--feed-state'."
  (plist-get hackernews-modern--feed-state prop))

(defun hackernews-modern--put (prop val)
  "Change value in `hackernews-modern--feed-state' of PROP to VAL."
  (setq hackernews-modern--feed-state (plist-put hackernews-modern--feed-state prop val)))

;;;;; URL helpers

(defun hackernews-modern--comments-url (id)
  "Return Hacker News website URL for item with ID."
  (format hackernews-modern-site-item-format id))

(defun hackernews-modern--format-api-url (fmt &rest args)
  "Construct a Hacker News API URL.
The result of passing FMT and ARGS to `format' is substituted in
`hackernews-modern-api-format'."
  (format hackernews-modern-api-format (apply #'format fmt args)))

(defun hackernews-modern--item-url (id)
  "Return Hacker News API URL for item with ID."
  (hackernews-modern--format-api-url "item/%s" id))

(defun hackernews-modern--feed-url (feed)
  "Return Hacker News API URL for FEED.
See `hackernews-modern-feed-names' for supported values of FEED."
  (hackernews-modern--format-api-url "%sstories" feed))

(defun hackernews-modern--feed-name (feed)
  "Lookup FEED in `hackernews-modern-feed-names'."
  (cdr (assoc-string feed hackernews-modern-feed-names)))

(defun hackernews-modern--feed-annotation (feed)
  "Annotate FEED during completion.
This is intended as an :annotation-function in
`completion-extra-properties'."
  (let ((name (hackernews-modern--feed-name feed)))
    (and name (concat " - " name))))

;;;;; HTTP and JSON (Asynchronous)

(defun hackernews-modern--retrieve-items-async (callback)
  "Retrieve items associated with current buffer asynchronously.
Calls CALLBACK when all items have been fetched.
Uses parallel queue system for non-blocking, fast downloads."
  (let* ((reg    (hackernews-modern--get :register))
         (nitem  (hackernews-modern--get :nitem))
         (offset (car reg))
         (ids    (cdr reg))
         (item-ids '()))
    ;; Build list of item IDs to fetch
    (dotimes (i nitem)
      (push (aref ids (+ offset i)) item-ids))
    (setq item-ids (nreverse item-ids))

    ;; Fetch items asynchronously using queue system
    (hackernews-modern-queue-fetch-items
     item-ids
     hackernews-modern-api-format
     (lambda (items)
       ;; Store items in buffer state
       (hackernews-modern--put :items items)
       ;; Call completion callback
       (funcall callback)))))

;;;; VIEW ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;; Faces

(defface hackernews-modern-link
  '((t :inherit link :underline nil))
  "Face used for story title links."
  :package-version '(hackernews-modern . "0.4.0"))

(defface hackernews-modern-comment-count
  '((t :inherit hackernews-modern-link))
  "Face used for comment counts."
  :package-version '(hackernews-modern . "0.4.0"))

(defface hackernews-modern-score
  '((t :inherit default))
  "Face used for the score of a story."
  :package-version '(hackernews-modern . "0.4.0"))

(defface hackernews-modern-logo
  '((t :foreground "#ff6600" :height 1.5))
  "Face used for the \"Y\" in the Hacker News logo."
  :package-version '(hackernews-modern . "0.8.0"))

(defface hackernews-modern-title-text
  '((t :foreground "#ff6600" :height 1.3))
  "Face used for the \"Hacker News\" title text."
  :package-version '(hackernews-modern . "0.8.0"))

(defface hackernews-modern-separator
  '((t :foreground "#666666"))
  "Face used for horizontal separator lines."
  :package-version '(hackernews-modern . "0.8.0"))

(defface hackernews-modern-score-modern
  '((t :foreground "#ff6600"))
  "Face used for story scores."
  :package-version '(hackernews-modern . "0.8.0"))

(defface hackernews-modern-author
  '((t :foreground "#0066cc"))
  "Face used for author names."
  :package-version '(hackernews-modern . "0.8.0"))

(defface hackernews-modern-feed-indicator
  '((t :foreground "#ff6600"))
  "Face used for the current feed indicator."
  :package-version '(hackernews-modern . "0.8.0"))

;;;;; Customization (visual)

(defcustom hackernews-modern-display-width 80
  "Maximum width for displaying hackernews-modern content."
  :package-version '(hackernews-modern . "0.8.0")
  :type 'integer)

(defcustom hackernews-modern-enable-emojis nil
  "Whether to display emojis in the interface.
When non-nil, feed navigation buttons and comment counts will
include emoji icons for visual enhancement."
  :package-version '(hackernews-modern . "0.8.0")
  :type 'boolean)

(defcustom hackernews-modern-before-render-hook ()
  "Hook called before rendering any new items."
  :package-version '(hackernews-modern . "0.4.0")
  :type 'hook)

(defcustom hackernews-modern-after-render-hook ()
  "Hook called after rendering any new items.
The position of point will not have been affected by the render."
  :package-version '(hackernews-modern . "0.4.0")
  :type 'hook)

(defcustom hackernews-modern-finalize-hook ()
  "Hook called as final step of loading any new items.
The position of point may have been adjusted after the render,
buffer-local feed state will have been updated and the hackernews-modern
buffer will be current and displayed in the selected window."
  :package-version '(hackernews-modern . "0.4.0")
  :type 'hook)

;;;;; UI helpers

(defconst hackernews-modern--separator-char ?-
  "Character used for horizontal separators.")

(defun hackernews-modern--string-separator ()
  "Return a separator string of `hackernews-modern-display-width' dashes."
  (make-string hackernews-modern-display-width hackernews-modern--separator-char))

(defun hackernews-modern--insert-separator ()
  "Insert a horizontal separator line."
  (insert "\n")
  (insert (propertize (hackernews-modern--string-separator)
                      'face 'hackernews-modern-separator))
  (insert "\n\n"))

(defun hackernews-modern--insert-logo ()
  "Insert the Hacker News logo."
  (insert "\n")
  (insert (propertize "Y " 'face 'hackernews-modern-logo))
  (insert (propertize "Hacker News" 'face 'hackernews-modern-title-text))
  (insert "\n\n"))

(defconst hackernews-modern--feed-buttons
  '(("top"  "🔥 " "View top stories"  hackernews-modern-top-stories)
    ("new"  "🆕 " "View new stories"  hackernews-modern-new-stories)
    ("best" "⭐ " "View best stories" hackernews-modern-best-stories)
    ("ask"  "❓ " "View ask stories"  hackernews-modern-ask-stories)
    ("show" "📺 " "View show stories" hackernews-modern-show-stories))
  "Feed button specs: (feed-key emoji help-text command).")

(defun hackernews-modern--insert-header (feed-name)
  "Insert the page header showing FEED-NAME and navigation buttons."
  (hackernews-modern--insert-logo)
  (dolist (spec hackernews-modern--feed-buttons)
    (let ((label (capitalize (nth 0 spec)))
          (emoji (nth 1 spec))
          (help  (nth 2 spec))
          (cmd   (nth 3 spec)))
      (widget-create 'push-button
                     :notify (lambda (&rest _) (call-interactively cmd))
                     :help-echo help
                     (format " %s%s " (if hackernews-modern-enable-emojis emoji "") label))
      (insert " ")))
  (widget-create 'push-button
                 :notify (lambda (&rest _) (hackernews-modern-reload))
                 :help-echo "Refresh current feed"
                 " ↻ Refresh ")
  (insert "\n\n")
  (insert (propertize (format "Showing: %s\n" feed-name)
                      'face 'hackernews-modern-feed-indicator))
  (insert "Keyboard: (n) Next | (p) Previous | (g) Refresh | (q) Quit\n")
  (hackernews-modern--insert-separator))

;;;;; Item rendering

(autoload 'xml-substitute-special "xml")

(defun hackernews-modern--render-item (item)
  "Render Hacker News ITEM in the current buffer using widgets."
  (let* ((id           (cdr (assq 'id          item)))
         (title        (cdr (assq 'title       item)))
         (score        (cdr (assq 'score       item)))
         (by           (cdr (assq 'by          item)))
         (item-url     (cdr (assq 'url         item)))
         (descendants  (cdr (assq 'descendants item)))
         (comments-url (hackernews-modern--comments-url id))
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
                        'face 'hackernews-modern-score-modern))
    (insert " | ")
    (widget-create 'push-button
                   :notify (lambda (&rest _)
                             (browse-url comments-url))
                   :help-echo (format "View comments: %s" comments-url)
                   :format "%[%v%]"
                   (format "%s%d comment%s"
                           (if hackernews-modern-enable-emojis "💬 " "")
                           (or descendants 0)
                           (if (= (or descendants 0) 1) "" "s")))
    (when by
      (insert " | by ")
      (insert (propertize by 'face 'hackernews-modern-author)))
    (insert "\n")
    (hackernews-modern--insert-separator)
    (put-text-property item-start (point) 'hackernews-modern-item-id id)))

;;;;; Buffer display

(defun hackernews-modern--display-items ()
  "Render items associated with the current buffer and display it."
  (let* ((reg        (hackernews-modern--get :register))
         (items      (hackernews-modern--get :items))
         (nitem      (length items))
         (feed       (hackernews-modern--get :feed))
         (feed-name  (hackernews-modern--feed-name feed))
         (first-load (= (buffer-size) 0))
         (inhibit-read-only t))
    (when first-load
      (hackernews-modern--insert-header feed-name))
    (run-hooks 'hackernews-modern-before-render-hook)
    (save-excursion
      (goto-char (point-max))
      (mapc #'hackernews-modern--render-item
            (cl-remove-if (lambda (item)
                            (or (eq item :null)
                                (cdr (assq 'deleted item))
                                (cdr (assq 'dead item))))
                          items)))
    (run-hooks 'hackernews-modern-after-render-hook)
    (use-local-map (make-composed-keymap (list widget-keymap hackernews-modern-mode-map)
                                         special-mode-map))
    (widget-setup)
    (when (and (require 'visual-fill-column nil t)
               (boundp 'visual-fill-column-width))
      (setq-local visual-fill-column-width hackernews-modern-display-width)
      (setq-local visual-fill-column-center-text t)
      (visual-fill-column-mode 1))
    (when (fboundp 'display-line-numbers-mode)
      (display-line-numbers-mode 0))
    (cond
     (first-load
      (goto-char (point-min))
      (widget-forward 1))
     ((not (or (<= nitem 0) hackernews-modern-preserve-point))
      (goto-char (point-max))
      (hackernews-modern-previous-item nitem)))
    (setcar reg (+ (car reg) nitem)))
  (read-only-mode 1)
  (pop-to-buffer (current-buffer) '((display-buffer-same-window)))
  (run-hooks 'hackernews-modern-finalize-hook))

;;;; CONTROLLER ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;;;; Customization (behavioral)

(defcustom hackernews-modern-preserve-point t
  "Whether to preserve point when loading more stories.
When nil, point is placed on first new item retrieved."
  :package-version '(hackernews-modern . "0.4.0")
  :type 'boolean)

(defcustom hackernews-modern-internal-browser-function
  (if (functionp 'eww-browse-url)
      #'eww-browse-url
    #'browse-url-text-emacs)
  "Function to load a given URL within Emacs.
See `browse-url-browser-function' for some possible options."
  :package-version '(hackernews-modern . "0.4.0")
  :type (cons 'radio (butlast (cdr (custom-variable-type
                                    'browse-url-browser-function)))))

;;;;; Keymaps

(defvar hackernews-modern-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "f" #'hackernews-modern-switch-feed)
    (define-key map "g" #'hackernews-modern-reload)
    (define-key map "m" #'hackernews-modern-load-more-stories)
    (define-key map "n" #'hackernews-modern-next-item)
    (define-key map "p" #'hackernews-modern-previous-item)
    map)
  "Keymap used in hackernews-modern buffer.")

;;;;; Major mode

(define-derived-mode hackernews-modern-mode special-mode "HN"
  "Mode for browsing Hacker News.

Key bindings:
\\<hackernews-modern-mode-map>
\\[hackernews-modern-next-item]		Move to next story.
\\[hackernews-modern-previous-item]		Move to previous story.
\\[hackernews-modern-load-more-stories]	Load more stories.
\\[hackernews-modern-reload]			Reload stories.
\\[hackernews-modern-switch-feed]		Switch feed.
\\<special-mode-map>\\[quit-window]	Quit.

\\{hackernews-modern-mode-map}"
  :interactive nil
  (setq hackernews-modern--feed-state ())
  (setq truncate-lines t)
  (buffer-disable-undo))

;;;;; Navigation

(defun hackernews-modern-next-item (&optional n)
  "Move to Nth next story (previous if N is negative).
N defaults to 1."
  (declare (modes hackernews-modern-mode))
  (interactive "p")
  (let ((count (or n 1))
        (separator-regex (concat "^" (regexp-quote (hackernews-modern--string-separator)) "$")))
    (if (< count 0)
        (hackernews-modern-previous-item (- count))
      (dotimes (_ count)
        (if (search-forward-regexp separator-regex nil t)
            (progn
              (forward-line 2)
              (beginning-of-line)
              (recenter))
          (message "No more stories"))))))

(defun hackernews-modern-previous-item (&optional n)
  "Move to Nth previous story (next if N is negative).
N defaults to 1."
  (declare (modes hackernews-modern-mode))
  (interactive "p")
  (let ((count (or n 1))
        (separator-regex (concat "^" (regexp-quote (hackernews-modern--string-separator)) "$")))
    (if (< count 0)
        (hackernews-modern-next-item (- count))
      (dotimes (_ count)
        (search-backward-regexp separator-regex nil t)
        (if (search-backward-regexp separator-regex nil t)
            (progn
              (forward-line 2)
              (beginning-of-line)
              (recenter))
          (goto-char (point-min))
          (widget-forward 1))))))

(defun hackernews-modern-first-item ()
  "Move point to the first story in the hackernews-modern buffer."
  (declare (modes hackernews-modern-mode))
  (interactive)
  (goto-char (point-min))
  (hackernews-modern-next-item))

;;;;; Orchestration

(defun hackernews-modern--fetch-feed-ids (feed callback)
  "Fetch list of item IDs from FEED asynchronously.
Calls CALLBACK with the vector of IDs."
  (let ((url (hackernews-modern--feed-url feed)))
    (url-retrieve
     url
     (lambda (status)
       (let ((ids nil))
         (condition-case err
             (progn
               (when (plist-get status :error)
                 (error "Failed to fetch feed: %S" (plist-get status :error)))
               (goto-char (point-min))
               (re-search-forward "\r\n\r\n\\|\n\n" nil t)
               (setq ids (json-parse-buffer)))
           (error
            (message "Error fetching feed list: %s" (error-message-string err))
            (setq ids (make-vector 0 nil))))
         (kill-buffer (current-buffer))
         (funcall callback ids)))
     nil t)))

(defun hackernews-modern--load-stories (feed n &optional append)
  "Retrieve and render at most N items from FEED asynchronously.
Create and setup corresponding hackernews-modern buffer if necessary.

If APPEND is nil, refresh the list of items from FEED and render
at most N of its top items.  Any previous hackernews-modern buffer
contents are overwritten.

Otherwise, APPEND should be a cons cell (OFFSET . IDS), where IDS
is the vector of item IDs corresponding to FEED and OFFSET
indicates where in IDS the previous retrieval and render left
off.  At most N of FEED's items starting at OFFSET are then
rendered at the end of the hackernews-modern buffer.

This function returns immediately; items are loaded asynchronously
and the buffer is updated when ready."
  (let* ((name   (hackernews-modern--feed-name feed))
         (offset (or (car append) 0)))
    (if append
        ;; Appending to existing feed - IDs already available
        (let ((ids (cdr append)))
          (with-current-buffer (get-buffer-create (format "*hackernews-modern %s*" name))
            (hackernews-modern--put :feed feed)
            (hackernews-modern--put :register (cons offset ids))
            (hackernews-modern--put :nitem
                                    (max 0 (min (- (length ids) offset)
                                                (prefix-numeric-value
                                                 (or n hackernews-modern-items-per-page)))))
            ;; Fetch items asynchronously
            (hackernews-modern--retrieve-items-async
             (lambda ()
               (hackernews-modern--display-items)))))
      ;; Fresh load - need to fetch feed IDs first
      (message "Retrieving %s..." name)
      (hackernews-modern--fetch-feed-ids
       feed
       (lambda (ids)
         (with-current-buffer (get-buffer-create (format "*hackernews-modern %s*" name))
           (let ((inhibit-read-only t))
             (erase-buffer))
           (remove-overlays)
           (hackernews-modern-mode)
           (hackernews-modern--put :feed feed)
           (hackernews-modern--put :register (cons offset ids))
           (hackernews-modern--put :nitem
                                   (max 0 (min (- (length ids) offset)
                                               (prefix-numeric-value
                                                (or n hackernews-modern-items-per-page)))))
           ;; Fetch items asynchronously
           (hackernews-modern--retrieve-items-async
            (lambda ()
              (hackernews-modern--display-items)))))))))

;;;;; Interactive commands

;;;###autoload
(defun hackernews-modern (&optional n)
  "Read top N Hacker News stories.
The feed is determined by `hackernews-modern-default-feed' and N defaults
to `hackernews-modern-items-per-page'."
  (interactive "P")
  (hackernews-modern--load-stories hackernews-modern-default-feed n))

(defun hackernews-modern-reload (&optional n)
  "Reload top N stories from the current feed.
N defaults to `hackernews-modern-items-per-page'."
  (declare (modes hackernews-modern-mode))
  (interactive "P")
  (unless (derived-mode-p #'hackernews-modern-mode)
    (user-error "Not a hackernews-modern buffer"))
  (hackernews-modern--load-stories
   (or (hackernews-modern--get :feed)
       (user-error "Buffer unassociated with feed"))
   n))

(defun hackernews-modern-load-more-stories (&optional n)
  "Load N more stories into the hackernews-modern buffer.
N defaults to `hackernews-modern-items-per-page'."
  (declare (modes hackernews-modern-mode))
  (interactive "P")
  (unless (derived-mode-p #'hackernews-modern-mode)
    (user-error "Not a hackernews-modern buffer"))
  (let ((feed (hackernews-modern--get :feed))
        (reg  (hackernews-modern--get :register)))
    (unless (and feed reg)
      (user-error "Buffer in invalid state"))
    (if (>= (car reg) (length (cdr reg)))
        (message "%s" (substitute-command-keys "\
End of feed; type \\[hackernews-modern-reload] to load new items."))
      (hackernews-modern--load-stories feed n reg))))

(defun hackernews-modern-switch-feed (&optional n)
  "Read top N stories from a feed chosen with completion.
N defaults to `hackernews-modern-items-per-page'."
  (interactive "P")
  (hackernews-modern--load-stories
   (let ((completion-extra-properties
          (list :annotation-function #'hackernews-modern--feed-annotation)))
     (completing-read
      (format-prompt "Hacker News feed" hackernews-modern-default-feed)
      hackernews-modern-feed-names nil t nil 'hackernews-modern-feed-history
      hackernews-modern-default-feed))
   n))

(defun hackernews-modern-top-stories (&optional n)
  "Read top N Hacker News top stories.
N defaults to `hackernews-modern-items-per-page'."
  (interactive "P")
  (hackernews-modern--load-stories "top" n))

(defun hackernews-modern-new-stories (&optional n)
  "Read top N Hacker News new stories.
N defaults to `hackernews-modern-items-per-page'."
  (interactive "P")
  (hackernews-modern--load-stories "new" n))

(defun hackernews-modern-best-stories (&optional n)
  "Read top N Hacker News best stories.
N defaults to `hackernews-modern-items-per-page'."
  (interactive "P")
  (hackernews-modern--load-stories "best" n))

(defun hackernews-modern-ask-stories (&optional n)
  "Read top N Hacker News ask stories.
N defaults to `hackernews-modern-items-per-page'."
  (interactive "P")
  (hackernews-modern--load-stories "ask" n))

(defun hackernews-modern-show-stories (&optional n)
  "Read top N Hacker News show stories.
N defaults to `hackernews-modern-items-per-page'."
  (interactive "P")
  (hackernews-modern--load-stories "show" n))

(defun hackernews-modern-job-stories (&optional n)
  "Read top N Hacker News job stories.
N defaults to `hackernews-modern-items-per-page'."
  (interactive "P")
  (hackernews-modern--load-stories "job" n))

(provide 'hackernews-modern)

;;; hackernews-modern.el ends here
