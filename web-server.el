;;; web-server.el --- Emacs Web Server

;; Copyright (C) 2013 Eric Schulte <schulte.eric@gmail.com>

;; Author: Eric Schulte <schulte.eric@gmail.com>
;; Keywords: http
;; License: GPLV3 (see the COPYING file in this directory)

;;; Commentary:

;; A web server in Emacs running handlers written in Emacs Lisp.
;;
;; Full support for GET and POST requests including URL-encoded
;; parameters and multipart/form data.
;;
;; See the examples/ directory for examples demonstrating the usage of
;; the Emacs Web Server.  The following launches a simple "hello
;; world" server.
;;
;;     (ws-start
;;      '(((lambda (_) t) .                         ; match every request
;;         (lambda (request)                        ; reply with "hello world"
;;           (with-slots (process) request
;;             (ws-response-header process 200 '("Content-type" . "text/plain"))
;;             (process-send-string process "hello world")))))
;;      9000)

;;; Code:
(require 'web-server-status-codes)
(require 'mail-parse)             ; to parse multipart data in headers
(require 'mm-encode)              ; to look-up mime types for files
(require 'url-util)               ; to decode url-encoded params
(require 'eieio)
(eval-when-compile (require 'cl))
(require 'cl-lib)

(defclass ws-server ()
  ((handlers :initarg :handlers :accessor handlers :initform nil)
   (process  :initarg :process  :accessor process  :initform nil)
   (port     :initarg :port     :accessor port     :initform nil)
   (requests :initarg :requests :accessor requests :initform nil)))

(defclass ws-request ()
  ((process  :initarg :process  :accessor process  :initform nil)
   (pending  :initarg :pending  :accessor pending  :initform "")
   (context  :initarg :context  :accessor context  :initform nil)
   (boundary :initarg :boundary :accessor boundary :initform nil)
   (index    :initarg :index    :accessor index    :initform 0)
   (active   :initarg :active   :accessor active   :initform nil)
   (headers  :initarg :headers  :accessor headers  :initform (list nil))))

(defvar ws-servers nil
  "List holding all web servers.")

(defvar ws-log-time-format "%Y.%m.%d.%H.%M.%S.%N"
  "Logging time format passed to `format-time-string'.")

(defvar ws-guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  "This GUID is defined in RFC6455.")

;;;###autoload
(defun ws-start (handlers port &optional log-buffer &rest network-args)
  "Start a server using HANDLERS and return the server object.

HANDLERS should be a list of cons of the form (MATCH . ACTION),
where MATCH is either a function (in which case it is called on
the request object) or a cons cell of the form (KEYWORD . STRING)
in which case STRING is matched against the value of the header
specified by KEYWORD.  In either case when MATCH returns non-nil,
then the function ACTION is called with two arguments, the
process and the request object.

Any supplied NETWORK-ARGS are assumed to be keyword arguments for
`make-network-process' to which they are passed directly.

For example, the following starts a simple hello-world server on
port 8080.

  (ws-start
   '(((:GET . \".*\") .
      (lambda (proc request)
        (process-send-string proc
         \"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nhello world\r\n\")
        t)))
   8080)

Equivalently, the following starts an identical server using a
function MATCH and the `ws-response-header' convenience
function.

  (ws-start
   '(((lambda (_) t) .
      (lambda (proc request)
        (ws-response-header proc 200 '(\"Content-type\" . \"text/plain\"))
        (process-send-string proc \"hello world\")
        t)))
   8080)

"
  (let ((server (make-instance 'ws-server :handlers handlers :port port))
        (log (when log-buffer (get-buffer-create log-buffer))))
    (setf (process server)
          (apply
           #'make-network-process
           :name "ws-server"
           :service (port server)
           :filter 'ws-filter
           :server t
           :nowait t
           :family 'ipv4
           :plist (append (list :server server)
                          (when log (list :log-buffer log)))
           :log (when log
                  (lambda (proc request message)
                    (let ((c (process-contact request))
                          (buf (plist-get (process-plist proc) :log-buffer)))
                      (with-current-buffer buf
                        (goto-char (point-max))
                        (insert (format "%s\t%s\t%s\t%s"
                                        (format-time-string ws-log-time-format)
                                        (first c) (second c) message))))))
           network-args))
    (push server ws-servers)
    server))

(defun ws-stop (server)
  "Stop SERVER."
  (setq ws-servers (remove server ws-servers))
  (mapc #'delete-process (append (mapcar #'car (requests server))
                                 (list (process server)))))

(defvar ws-http-common-methods '(GET HEAD POST PUT DELETE TRACE)
  "HTTP methods from http://www.w3.org/Protocols/rfc2616/rfc2616-sec9.html.")

(defvar ws-http-method-rx
  (format "^\\(%s\\) \\([^[:space:]]+\\) \\([^[:space:]]+\\)$"
          (mapconcat #'symbol-name ws-http-common-methods "\\|")))

(defun ws-parse-query-string (string)
  "Thin wrapper around `url-parse-query-string'."
  (mapcar (lambda (pair) (cons (first pair) (second pair)))
          (url-parse-query-string string nil 'allow-newlines)))

(defun ws-parse (proc string)
  "Parse HTTP headers in STRING reporting errors to PROC."
  (cl-flet ((to-keyword (s) (intern (concat ":" (upcase s)))))
    (cond
     ;; Method
     ((string-match ws-http-method-rx string)
      (let ((method (to-keyword (match-string 1 string)))
            (url (match-string 2 string)))
        (if (string-match "?" url)
            (cons (cons method (substring url 0 (match-beginning 0)))
                  (ws-parse-query-string
                   (url-unhex-string (substring url (match-end 0)))))
          (list (cons method url)))))
     ;; Authorization
     ((string-match "^AUTHORIZATION: \\([^[:space:]]+\\) \\(.*\\)$" string)
      (let ((protocol (to-keyword (match-string 1 string)))
            (credentials (match-string 2 string)))
        (list (cons :AUTHORIZATION
                    (cons protocol
                          (case protocol
                            (:BASIC
                             (let ((cred (base64-decode-string credentials)))
                               (if (string-match ":" cred)
                                   (cons (substring cred 0 (match-beginning 0))
                                         (substring cred (match-end 0)))
                                 (ws-error proc "bad credentials: %S" cred))))
                            (t (ws-error proc "un-support protocol: %s"
                                         protocol))))))))
     ;; All other headers
     ((string-match "^\\([^[:space:]]+\\): \\(.*\\)$" string)
      (list (cons (to-keyword (match-string 1 string))
                  (match-string 2 string))))
     (:otherwise (ws-error proc "bad header: %S" string) nil))))

(defun ws-trim (string)
  (while (and (> (length string) 0)
              (or (and (string-match "[\r\n]" (substring string -1))
                       (setq string (substring string 0 -1)))
                  (and (string-match "[\r\n]" (substring string 0 1))
                       (setq string (substring string 1))))))
  string)

(defun ws-parse-multipart/form (proc string)
  ;; ignore empty and non-content blocks
  (when (string-match "Content-Disposition:[[:space:]]*\\(.*\\)\r\n" string)
    (let ((dp (cdr (mail-header-parse-content-disposition
                    (match-string 1 string))))
          (last-index (match-end 0))
          index)
      ;; every line up until the double \r\n is a header
      (while (and (setq index (string-match "\r\n" string last-index))
                  (not (= index last-index)))
        (setcdr (last dp) (ws-parse proc (substring string last-index index)))
        (setq last-index (+ 2 index)))
      ;; after double \r\n is all content
      (cons (cdr (assoc 'name dp))
            (cons (cons 'content (substring string (+ 2 last-index)))
                  dp)))))

(defun ws-filter (proc string)
  (with-slots (handlers requests) (plist-get (process-plist proc) :server)
    (unless (cl-find-if (lambda (c) (equal proc (process c))) requests)
      (push (make-instance 'ws-request :process proc) requests))
    (let ((request (cl-find-if (lambda (c) (equal proc (process c))) requests)))
      (with-slots (pending) request (setq pending (concat pending string)))
      (unless (active request) ; don't re-start if request is being parsed
        (setf (active request) t)
        (when (not (eq (catch 'close-connection
                         (if (ws-parse-request request)
                             (ws-call-handler request handlers)
                           :keep-alive))
                       :keep-alive))
          (setq requests (cl-remove-if (lambda (r) (eql proc (process r))) requests))
          (delete-process proc))))))

(defun ws-parse-request (request)
  "Parse request STRING from REQUEST with process PROC.
Return non-nil only when parsing is complete."
  (catch 'finished-parsing-headers
    (with-slots (process pending context boundary headers index) request
      (let ((delimiter (concat "\r\n" (if boundary (concat "--" boundary) "")))
            ;; Track progress through string, always work with the
            ;; section of string between INDEX and NEXT-INDEX.
            next-index)
        ;; parse headers and append to request
        (while (setq next-index (string-match delimiter pending index))
          (let ((tmp (+ next-index (length delimiter))))
            (if (= index next-index) ; double \r\n ends current run of headers
                (case context
                  ;; Parse URL data.
                  ;; http://www.w3.org/TR/html4/interact/forms.html#h-17.13.4
                  (application/x-www-form-urlencoded
                   (mapc (lambda (pair) (setcdr (last headers) (list pair)))
                         (ws-parse-query-string
                          (replace-regexp-in-string
                           "\\+" " "
                           (ws-trim (substring pending index)))))
                   (throw 'finished-parsing-headers t))
                  ;; Set custom delimiter for multipart form data.
                  (multipart/form-data
                   (setq delimiter (concat "\r\n--" boundary)))
                  ;; No special context so we're done.
                  (t (throw 'finished-parsing-headers t)))
              (if (eql context 'multipart/form-data)
                  (progn
                    (setcdr (last headers)
                            (list (ws-parse-multipart/form process
                                    (substring pending index next-index))))
                    ;; Boundary suffixed by "--" indicates end of the headers.
                    (when (and (> (length pending) (+ tmp 2))
                               (string= (substring pending tmp (+ tmp 2)) "--"))
                      (throw 'finished-parsing-headers t)))
                ;; Standard header parsing.
                (let ((header (ws-parse process (substring pending
                                                           index next-index))))
                  ;; Content-Type indicates that the next double \r\n
                  ;; will be followed by a special type of content which
                  ;; will require special parsing.  Thus we will note
                  ;; the type in the CONTEXT variable for parsing
                  ;; dispatch above.
                  (if (and (caar header) (eql (caar header) :CONTENT-TYPE))
                      (cl-destructuring-bind (type &rest data)
                          (mail-header-parse-content-type (cdar header))
                        (setq boundary (cdr (assoc 'boundary data)))
                        (setq context (intern (downcase type))))
                    ;; All other headers are collected directly.
                    (setcdr (last headers) header)))))
            (setq index tmp)))))
    (setf (active request) nil)
    nil))

 (defun ws-call-handler (request handlers)
  (catch 'matched-handler
    (mapc (lambda (handler)
            (let ((match (car handler))
                  (function (cdr handler)))
              (when (or (and (consp match)
                             (assoc (car match) (headers request))
                             (string-match (cdr match)
                                           (cdr (assoc (car match)
                                                       (headers request)))))
                        (and (functionp match) (funcall match request)))
                (throw 'matched-handler
                       (condition-case e (funcall function request)
                         (error (ws-error (process request)
                                           "Caught Error: %S" e)))))))
          handlers)
    (ws-error (process request) "no handler matched request: %S"
               (headers request))))

(defun ws-error (proc msg &rest args)
  (let ((buf (plist-get (process-plist proc) :log-buffer))
        (c (process-contact proc)))
    (when buf
      (with-current-buffer buf
        (goto-char (point-max))
        (insert (format "%s\t%s\t%s\tWS-ERROR: %s"
                        (format-time-string ws-log-time-format)
                        (first c) (second c)
                        (apply #'format msg args)))))
    (apply #'ws-send-500 proc msg args)))


;;; Web Socket

;; Binary framing protocol
;; from http://tools.ietf.org/html/rfc6455#section-5.2
;;
;;  0                   1                   2                   3
;;  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
;; +-+-+-+-+-------+-+-------------+-------------------------------+
;; |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
;; |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
;; |N|V|V|V|       |S|             |   (if payload len==126/127)   |
;; | |1|2|3|       |K|             |                               |
;; +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
;; |     Extended payload length continued, if payload len == 127  |
;; + - - - - - - - - - - - - - - - +-------------------------------+
;; |                               |Masking-key, if MASK set to 1  |
;; +-------------------------------+-------------------------------+
;; | Masking-key (continued)       |          Payload Data         |
;; +-------------------------------- - - - - - - - - - - - - - - - +
;; :                     Payload Data continued ...                :
;; + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
;; |                     Payload Data continued ...                |
;; +---------------------------------------------------------------+
;;
(defun int-to-bits (int size)
  (let ((result (make-bool-vector size nil)))
    (mapc (lambda (place)
            (let ((val (expt 2 place)))
              (when (>= int val)
                (setq int (- int val))
                (aset result place t))))
          (reverse (number-sequence 0 (- size 1))))
    (reverse (coerce result 'list))))

(defun bits-to-int (bits)
  (let ((place 0))
    (reduce #'+ (mapcar (lambda (bit)
                          (prog1 (if bit (expt 2 place) 0) (incf place)))
                        (reverse bits)))))

(defun ws/web-socket-mask (masking-key data)
  (let ((masking-data (apply #'concat (make-list (+ 1 (/ (length data) 4))
                                                 masking-key))))
    (apply #'string (cl-mapcar #'logxor masking-data data))))

(defun ws-web-socket-filter (proc string)
  "Web socket filter to pass whole frames to the client.
See RFC6455."
  (let ((index 0))
    (cl-flet ((bits (length)
                    (apply #'append
                           (mapcar (lambda (int) (int-to-bits int 8))
                                   (subseq string index (incf index length))))))
      (let ((data (plist-get (process-plist proc) :pending))
            fin rsvs opcode mask pl mask-key)
        (let ((byte (bits 1)))
          (setq fin (car byte)
                rsvs (subseq byte 1 4)
                opcode (let ((it (bits-to-int (subseq byte 4))))
                         (case it
                           (0 :CONTINUATION)
                           (1 :TEXT)
                           (2 :BINARY)
                           ((3 4 5 6 7) :NON-CONTROL)
                           (9 :PING)
                           (10 :PONG)
                           ((11 12 13 14 15) :CONTROL)
                           (t (ws-error proc "Web Socket Fail: bad opcode %d"
                                        it))))))
        (unless (cl-every #'null rsvs)
          (ws-error proc "Web Socket Fail: non-zero RSV 1 2 or 3"))
        (let ((byte (bits 1)))
          (setq mask (car byte)
                pl (bits-to-int (subseq byte 1))))
        (unless (eq mask t)
          (ws-error proc "Web Socket Fail: client must mask data"))
        (cond
         ((= pl 126) (setq pl (bits-to-int (bits 2))))
         ((= pl 127) (setq pl (bits-to-int (bits 8)))))
        (when mask (setq mask-key (subseq string index (incf index 4))))
        (setq data (concat data
                           (ws/web-socket-mask
                            mask-key (subseq string index (+ index pl)))))
        (if fin
            (message "received message %S" data)
          (set-process-plist proc (list :data data)))))))


;;; Convenience functions to write responses
(defun ws-response-header (proc code &rest headers)
  "Send the headers for an HTTP response to PROC.
Currently CODE should be an HTTP status code, see
`ws-status-codes' for a list of known codes."
  (let ((headers
         (cons
          (format "HTTP/1.1 %d %s" code (cdr (assoc code ws-status-codes)))
          (mapcar (lambda (h) (format "%s: %s" (car h) (cdr h))) headers))))
    (setcdr (last headers) (list "" ""))
    (process-send-string proc (mapconcat #'identity headers "\r\n"))))

(defun ws-send-500 (proc &rest msg-and-args)
  "Send 500 \"Internal Server Error\" to PROC with an optional message."
  (ws-response-header proc 500
    '("Content-type" . "text/plain"))
  (process-send-string proc (if msg-and-args
                                (apply #'format msg-and-args)
                              "500 Internal Server Error"))
  (throw 'close-connection nil))

(defun ws-send-404 (proc &rest msg-and-args)
  "Send 404 \"Not Found\" to PROC with an optional message."
  (ws-response-header proc 404
    '("Content-type" . "text/plain"))
  (process-send-string proc (if msg-and-args
                                (apply #'format msg-and-args)
                              "404 Not Found"))
  (throw 'close-connection nil))

(defun ws-send-file (proc path &optional mime-type)
  "Send PATH to PROC.
Optionally explicitly set MIME-TYPE, otherwise it is guessed by
`mm-default-file-encoding'."
  (let ((mime (or mime-type
                  (mm-default-file-encoding path)
                  "application/octet-stream")))
    (ws-response-header proc 200 (cons "Content-type" mime))
    (process-send-string proc
      (with-temp-buffer
        (insert-file-contents-literally path)
        (buffer-string)))))

(defun ws-in-directory-p (parent path)
  "Check if PATH is under the PARENT directory.
If so return PATH, if not return nil."
  (let ((expanded (expand-file-name path parent)))
    (and (>= (length expanded) (length parent))
         (string= parent (substring expanded 0 (length parent)))
         expanded)))

(defun ws-web-socket-handshake (key)
  "Perform the handshake defined in RFC6455."
  (base64-encode-string (sha1 (concat (ws-trim key) ws-guid) nil nil 'binary)))

(provide 'web-server)
;;; web-server.el ends here
