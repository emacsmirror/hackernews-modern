;;; hackernews-modern-queue.el --- Async queue for fetching HN items -*- lexical-binding: t -*-

;; Copyright (C) 2012-2025 The Hackernews.el Authors

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

;; Parallel queue system for fetching Hacker News items asynchronously.
;; This provides non-blocking, concurrent fetching with timeout support,
;; error handling, and progress tracking.
;;
;; Based on the queue system from org-social.el by Andros Fenollosa.

;;; Code:

(require 'url)
(require 'json)
(require 'seq)

;; Queue state
(defvar hackernews-modern-queue--queue nil
  "Queue of item IDs to fetch.")

(defvar hackernews-modern-queue--active-workers 0
  "Number of currently active download workers.")

(defvar hackernews-modern-queue--max-concurrent 5
  "Maximum number of concurrent downloads.
HN API is fast and reliable, so we can use more concurrent connections
than typical RSS feeds.")

(defvar hackernews-modern-queue--completion-callback nil
  "Callback to call when all items have been fetched.")

(defvar hackernews-modern-queue--api-format nil
  "Format string for API URLs, set during initialization.")

(defun hackernews-modern-queue--initialize (item-ids api-format callback)
  "Initialize the queue with ITEM-IDS, API-FORMAT and CALLBACK.
CALLBACK will be called with a vector of item alists when complete."
  (setq hackernews-modern-queue--queue
        (mapcar (lambda (id)
                  `((:id . ,id)
                    (:status . :pending)
                    (:item . nil)))
                item-ids))
  (setq hackernews-modern-queue--api-format api-format)
  (setq hackernews-modern-queue--completion-callback callback)
  (setq hackernews-modern-queue--active-workers 0))

(defun hackernews-modern-queue--update-status (id status)
  "Update the status of queue item with ID to STATUS."
  (setq hackernews-modern-queue--queue
        (mapcar (lambda (item)
                  (if (equal (alist-get :id item) id)
                      (let ((new-item (copy-tree item)))
                        (setcdr (assoc :status new-item) status)
                        new-item)
                    item))
                hackernews-modern-queue--queue)))

(defun hackernews-modern-queue--update-item (id item-data)
  "Update the item data of queue item with ID to ITEM-DATA."
  (setq hackernews-modern-queue--queue
        (mapcar (lambda (item)
                  (if (equal (alist-get :id item) id)
                      (let ((new-item (copy-tree item)))
                        (setcdr (assoc :item new-item) item-data)
                        new-item)
                    item))
                hackernews-modern-queue--queue)))

(defun hackernews-modern-queue--fetch-item (id callback error-callback)
  "Fetch item ID asynchronously using `url-retrieve'.
Calls CALLBACK with item alist on success, ERROR-CALLBACK on failure.
Includes a 10-second timeout to prevent hanging downloads."
  (let ((timeout-timer nil)
        (callback-called nil)
        (url-buffer nil)
        (url (format hackernews-modern-queue--api-format
                     (format "item/%s" id))))
    (setq url-buffer
          (url-retrieve
           url
           (lambda (status)
             ;; Cancel timeout timer if it exists
             (when timeout-timer
               (cancel-timer timeout-timer))

             ;; Only execute callback once
             (unless callback-called
               (setq callback-called t)

               (let ((result nil))
                 (condition-case err
                     (progn
                       ;; Check for errors first
                       (when (plist-get status :error)
                         (error "Download failed: %S" (plist-get status :error)))

                       ;; Check HTTP status
                       (goto-char (point-min))
                       (if (re-search-forward "^HTTP/[0-9]\\.[0-9] \\([0-9]\\{3\\}\\)" nil t)
                           (let ((status-code (string-to-number (match-string 1))))
                             (if (and (>= status-code 200) (< status-code 300))
                                 (progn
                                   ;; Success - extract JSON content
                                   (goto-char (point-min))
                                   (when (re-search-forward "\r\n\r\n\\|\n\n" nil t)
                                     (setq result (json-parse-buffer :object-type 'alist))))
                               ;; HTTP error
                               (message "HTTP %d error fetching item %s" status-code id)
                               (setq result nil)))
                         ;; No HTTP status found
                         (message "Invalid HTTP response for item %s" id)
                         (setq result nil)))
                   (error
                    (message "Error fetching item %s: %s" id (error-message-string err))
                    (setq result nil)))

                 ;; Kill buffer to avoid accumulation
                 (kill-buffer (current-buffer))

                 ;; Call appropriate callback
                 (if result
                     (funcall callback result)
                   (funcall error-callback)))))
           nil t))

    ;; Set up timeout timer (10 seconds for HN API)
    (setq timeout-timer
          (run-at-time 10 nil
                       (lambda ()
                         (unless callback-called
                           (setq callback-called t)
                           (message "Timeout fetching item %s (10 seconds)" id)
                           ;; Kill the url-retrieve buffer if it exists
                           (when (and url-buffer (buffer-live-p url-buffer))
                             ;; First kill the process to avoid interactive prompt
                             (let ((proc (get-buffer-process url-buffer)))
                               (when (and proc (process-live-p proc))
                                 (delete-process proc)))
                             ;; Now kill the buffer safely
                             (kill-buffer url-buffer))
                           (funcall error-callback)))))))

(defun hackernews-modern-queue--process-next-pending ()
  "Process the next pending item in the queue if worker slots available."
  (when (< hackernews-modern-queue--active-workers hackernews-modern-queue--max-concurrent)
    (let ((pending-item (seq-find (lambda (item) (eq (alist-get :status item) :pending))
                                  hackernews-modern-queue--queue)))
      (when pending-item
        (let ((id (alist-get :id pending-item)))
          ;; Mark as processing and increment active workers
          (hackernews-modern-queue--update-status id :processing)
          (setq hackernews-modern-queue--active-workers (1+ hackernews-modern-queue--active-workers))

          ;; Start the download
          (hackernews-modern-queue--fetch-item
           id
           ;; Success callback
           (lambda (item-data)
             (hackernews-modern-queue--update-status id :done)
             (hackernews-modern-queue--update-item id item-data)
             (setq hackernews-modern-queue--active-workers (1- hackernews-modern-queue--active-workers))
             ;; Process next pending item with small delay to avoid overwhelming API
             (run-at-time 0.05 nil #'hackernews-modern-queue--process-next-pending)
             (hackernews-modern-queue--check-completion))
           ;; Error callback
           (lambda ()
             (hackernews-modern-queue--update-status id :error)
             (setq hackernews-modern-queue--active-workers (1- hackernews-modern-queue--active-workers))
             ;; Process next pending item with small delay
             (run-at-time 0.05 nil #'hackernews-modern-queue--process-next-pending)
             (hackernews-modern-queue--check-completion))))))))

(defun hackernews-modern-queue--process ()
  "Process the queue asynchronously with limited concurrency."
  ;; Reset active workers counter
  (setq hackernews-modern-queue--active-workers 0)

  ;; Launch initial batch (up to max concurrent) with staggered start
  ;; HN API is fast, so we use shorter delays (0.05s between launches)
  (dotimes (i hackernews-modern-queue--max-concurrent)
    (run-at-time (* i 0.05) nil #'hackernews-modern-queue--process-next-pending)))

(defun hackernews-modern-queue--check-completion ()
  "Check if the download queue is complete and call callback if done."
  (let* ((total (length hackernews-modern-queue--queue))
         (done (length (seq-filter (lambda (i) (eq (alist-get :status i) :done))
                                   hackernews-modern-queue--queue)))
         (failed (length (seq-filter (lambda (i) (eq (alist-get :status i) :error))
                                     hackernews-modern-queue--queue)))
         (in-progress (seq-filter
                       (lambda (i) (or
                                    (eq (alist-get :status i) :processing)
                                    (eq (alist-get :status i) :pending)))
                       hackernews-modern-queue--queue)))

    ;; Show progress for longer downloads
    (when (and (> total 10) (> (length in-progress) 0))
      (message "Loading items... %d/%d completed%s"
               done total
               (if (> failed 0) (format " (%d failed)" failed) "")))

    (when (= (length in-progress) 0)
      ;; All downloads complete - collect results in order
      (let ((items (make-vector total nil))
            (index 0))
        ;; Fill vector with results, maintaining original order
        ;; Use :null for failed items (will be filtered later)
        (dolist (queue-item hackernews-modern-queue--queue)
          (aset items index
                (if (eq (alist-get :status queue-item) :done)
                    (alist-get :item queue-item)
                  :null))
          (setq index (1+ index)))

        ;; Final status message
        (if (> failed 0)
            (message "Loaded %d items (%d failed)" done failed)
          (message "Loaded %d items" done))

        ;; Call completion callback
        (when hackernews-modern-queue--completion-callback
          (funcall hackernews-modern-queue--completion-callback items))))))

;;;###autoload
(defun hackernews-modern-queue-fetch-items (item-ids api-format callback)
  "Fetch items with ITEM-IDS asynchronously and call CALLBACK with results.
API-FORMAT is the format string for constructing API URLs.
CALLBACK will be called with a vector of item alists.

Each item alist has the HN API structure with keys like:
  id, title, url, score, by, descendants, etc.

Failed items will be represented as :null in the result vector.

Returns immediately and processes items in parallel."
  (if (null item-ids)
      (progn
        (message "No item IDs provided")
        (funcall callback (make-vector 0 nil)))
    (let ((n (length item-ids)))
      (message "Fetching %d item%s..." n (if (> n 1) "s" ""))
      (hackernews-modern-queue--initialize item-ids api-format callback)
      (hackernews-modern-queue--process))))

(provide 'hackernews-modern-queue)
;;; hackernews-modern-queue.el ends here
