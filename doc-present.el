;;; doc-present.el --- Present slides with Emacs

;; Copyright (C) 2013 David Engster

;; Author: David Engster <deng@randomsample.de>
;; Keywords: presentation
;;
;; This file is not part of GNU Emacs.
;;
;; doc-present.el is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; doc-present.el is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;; Commentary:

;; Being fed up with the existing PDF viewers and their lacking
;; capabilities for doing presentations, I decided that Emacs must
;; save the day yet once again.

;; This package is meant to display presentation slides with a two
;; monitor setup.  On one screen it shows the actual slides, and on
;; the other a so called "presenter screen", showing not only the
;; current slide but also the next one, a timer and also optional
;; notes which can be drawn from an Org file.  It also features an
;; overview mode to quickly select certain slides.

;; This package uses doc-view, which ships with Emacs, to render the
;; actual document.  So if you'd like to change how the document is
;; rendered, look at the doc-view variables.  Most importantly, you
;; should increase `doc-view-resolution' (300 should be enough for a
;; projector, but large TFTs might require more).  Also, doc-present
;; should work with any format which doc-view is able to render,
;; though I am only testing with PDFs.

;; Your Emacs must be build with Imagemagick support for this to work
;; correctly.  This also implies that currently this won't work on W32
;; or OSX.  Also, I'm pretty sure that you'll need Emacs version 24.x.

;; Usage in a nutshell: Load a PDF file into Emacs, which should
;; trigger doc-view mode.  Wait till the whole document was rendered
;; (look in the modeline).  Then do M-x doc-present-start and follow
;; the instructions.

;; Keys:
;;  Left/Right, Up/Down, PgUp/PgDown: Previous/Next Slide
;;  Space, Return, Mouse-Click: Next Slide
;;  .: Black screen
;;  f: Toggle fullscreen of slide frame
;;  s: Start/Stop Timer
;;  o: Slide overview (on presenter frame)
;;  m: create a new main slide frame
;;  h: Quick help
;;  q: Quit

;; In Slide Overview:
;;
;;  left/right/up/down: Choose slide
;;  Return: Display slide in main slide frame, keep overview mode
;;  Space: Display slide in main slide frame, switch to presenter mode
;;  o: Show overview on slide frame as well
;;  q: Quit overview and return to presenter mode

;;; Code:

(require 'doc-view)
(eval-when-compile (require 'cl))

(declare-function org-narrow-to-subtree "org")
(declare-function org-map-entries "org")

(defgroup doc-present nil
  "Present slides using Emacs."
  :group 'applications
  :group 'data
  :group 'multimedia
  :prefix "doc-present-")

;; User options

(defcustom doc-present-slide-frame-background-color "white"
  "Color for the slide frame background.
It might be that your slides do not fit exactly into a frame, so
you should choose the color which matches those of your slides.
Also, Emacs always reserves the rightmost column for displaying
continuation or truncation characters, so this column will have
this color.  However, since we display the frame with a tiny
font, this should be hardly noticeable (see also
`doc-present-tiny-xft-font')."
  :type 'color
  :group 'doc-present)

(defcustom doc-present-current-slide-width 600
  "Width for displaying the current slide."
  :type 'number
  :group 'doc-present)

(defcustom doc-present-next-slide-width 500
  "Width for displaying the following slide."
  :type 'number
  :group 'doc-present)

(defcustom doc-present-overview-image-width 200
  "Width of slides in Overview mode."
  :type 'number
  :group 'doc-present)

(defcustom doc-present-presenter-layout
  "%W  Current Slide:  %N / %M   Time: %T \n%C %N\n%O"
  "Layout for the presenter screen.
The following keys can be used:
%W: Stopwatch timer
%T: Current time
%N,%M: Current/max slide number
%C,%N: Current/next slide image
%O: Org notes"
  :type 'string
  :group 'doc-present)

(defcustom doc-present-stopwatch-format "%.2m:%.2s"
  "Time format of the stop watch.
See `format-seconds' on how to use thise."
  :type 'string
  :group 'doc-present)

(defcustom doc-present-clock-time-format "%H:%M"
  "Time format for the clock.
See `format-time-string' on how to use this."
  :type 'string
  :group 'doc-present)

(defcustom doc-present-slide-frame-display nil
  "Display specification for slide frame.
You will only need to set this if your secondary monitor is
treated as a separate display by the X server, like \":0.1\".  If
you don't know what that means, just leave it at 'nil', which
means to use the default display; this is the correct choice for
xrandr/TwinView setups."
  :type '(choice :tag "Display for slide frame"
		 (const :tag "Default")
		 string)
  :group 'doc-present)

;; Other options

(defvar doc-present-presenter-buffer-name "*doc-present main*"
  "Name of the presenter buffer.")
(defvar doc-present-slide-buffer-name "*doc-present slide*"
  "Name of the slide buffer.")
(defvar doc-present-overview-buffer-name "*doc-present overview*"
  "Name of the overview buffer.")

(defvar doc-present-presenter-widgets
  '(("%W" doc-present-insert-stopwatch)
    ("%T" doc-present-insert-clock)
    ("%N" doc-present-insert-current-slide-number)
    ("%M" doc-present-insert-max-slide-number)
    ("%C" doc-present-insert-current-slide-image)
    ("%N" doc-present-insert-next-slide-image)
    ("%O" doc-present-insert-org-notes))
  "Alist which defines what to show for which keys.
If you'd like to define new keys for
`doc-present-presenter-layout', just put them here together with
the corresponding display function.")

(defvar doc-present-help-text
  "Press 'q' to exit this buffer.\n\n
Right, Down, PgDown, Space, Return: Next Slide
Left, Up, PgUp: Previous Slide
f: Toggle fullscreen of slide frame
s: Start/Stop Timer
.: Black out screen
o: Slide overview
m: Create new slide frame
h,?: This
q: Quit\n")

;; Faces

(defface doc-present-stopwatch-face
  '((t :height 300))
  "Face for displaying the stopwatch.")

(defface doc-present-clock-face
  '((t :height 300))
  "Face for displaying the clock.")

(defface doc-present-slide-number-face
  '((t :height 300))
  "Face for displaying the slide number.")

(defface doc-present-notes-face
  '((t :height 200))
  "Face for displaying the notes.")

(defface doc-present-tiny-xft-font
  '((t :family "Bitstream Charter" :height 15))
  "Tiny font for the slide display frame.
This should be a really tiny font which will be chosen for
displaying the main slide frame.  The reason for this is a bit
peculiar: Emacs frames cannot have arbitrary sizes, but are
multiples of the font's width and height.  Hence, the smaller the
frame's font, the more flexibility you have in choosing the
frame's size.  The other reason is that without fringes, the
rightmost column is always reserved for displaying
truncation/continuation characters, hence it cannot be used for
the slide.  The smaller the font, the less noticeable this
rightmost column will be.")

;; Internal variables

(defstruct doc-present-status filename current max sframe pframe
	   cachedir seconds-overlay clock-overlay slide-overlay
	   notes seconds oldface oldsize renderwin slide-max-size
	   slide-size aspect)

(defvar doc-present--st (make-doc-present-status))

(defvar doc-present--notes nil)
(defvar doc-present--stopwatch-timer nil)
(defvar doc-present--clock-timer nil)

;; Code

;; `user-error' isn't defined in Emacs < 24.3
(unless (fboundp 'user-error)
  (defalias 'user-error 'error))

(defun doc-present ()
  (interactive)
  (when doc-view-current-converter-processes
    (user-error "Conversion not finished yet"))
  (let ((st doc-present--st)
	size)
    (when (not (eq major-mode 'doc-view-mode))
      (user-error "Not a doc-view buffer"))
    ;; Initialize our status structure
    (setf (doc-present-status-pframe st) (selected-frame))
    (setf (doc-present-status-cachedir st) (doc-view-current-cache-dir))
    (setf (doc-present-status-current st) 1)
    (setf (doc-present-status-max st) (doc-view-last-page-number))
    (setf (doc-present-status-filename st) (buffer-file-name))
    (setf (doc-present-status-seconds st) 0)
    ;; Set aspect ratio of slides
    (setq size
	  (image-size
	   (create-image
	    (expand-file-name
	     "page-1.png"
	     (doc-present-status-cachedir doc-present--st))) t))
    (setf (doc-present-status-aspect st) (/ (float (car size)) (cdr size)))
    ;; Read in notes file
    (doc-present-snarf-notes-from-orgfile)
    ;; Create slide and presenter frames
    (doc-present-create-slide-frame)
    (doc-present-create-presenter-frame)
    (message "Press 'h' for help.")))

(defvar doc-present-mode-map)
(defun doc-present-mode ()
  (interactive)
  (kill-all-local-variables)
  (setq major-mode 'doc-present-mode)
  (setq mode-name "doc-present")
  (set-syntax-table text-mode-syntax-table)
  (use-local-map doc-present-mode-map)
  (setq buffer-read-only t))

(defvar doc-present-mode-map
  (let ((map (make-keymap)))
    (define-key map [(right)] 'doc-present-next-slide)
    (define-key map [(left)] 'doc-present-previous-slide)
    (define-key map [(up)] 'doc-present-next-slide)
    (define-key map [(down)] 'doc-present-previous-slide)
    (define-key map [(prior)] 'doc-present-next-slide)
    (define-key map [(return)] 'doc-present-next-slide)
    (define-key map [(next)] 'doc-present-previous-slide)
    (define-key map [(s)] 'doc-present-toggle-stopwatch)
    (define-key map [(f)] 'doc-present-toggle-fullscreen)
    (define-key map [(q)] 'doc-present-quit)
    (define-key map [(o)] 'doc-present-overview)
    (define-key map [(.)] 'doc-present-toggle-black-out)
    (define-key map [(m)] 'doc-present-create-slide-frame)
    (define-key map [(h)] 'doc-present-help)
    (define-key map [(q)] 'doc-present-quit)
    map)
  "")

(defun doc-present-create-slide-frame ()
  (interactive)
  (when (frame-live-p (doc-present-status-sframe doc-present--st))
    (user-error "Slide frame already existing"))
  (with-selected-frame
      (let ((parameters
	     `((minibuffer . nil)
	       (left-fringe . 0)
	       (right-fringe . 0)
	       (menu-bar-lines . 0)
	       (internal-border-width . 0)
	       (vertical-scroll-bars . nil)
	       (unsplittable . t)
	       (border-color . ,doc-present-slide-frame-background-color)
	       (cursor-type . nil)
	       (tool-bar-lines . 0))))
	(when doc-present-slide-frame-display
	  (setq parameters
		(append parameters
			`((display . ,doc-present-slide-frame-display)))))
	(make-frame parameters))
    (setf (doc-present-status-sframe doc-present--st) (selected-frame))
    (setf (doc-present-status-oldface doc-present--st)
	  (cons (face-attribute 'default :family)
		(face-attribute 'default :height)))
    (switch-to-buffer (get-buffer-create doc-present-slide-buffer-name))
    (doc-present-update-main-slide t)
    (doc-present-mode)
    (setq mode-line-format nil)
    (split-window-below 5)
    (switch-to-buffer (get-buffer-create "*doc-present-help-slide*"))
    (erase-buffer)
    (insert (concat "This is the main slide frame.\n\nDrag it to the "
		    "presentation monitor and press 'f' to switch to "
		    "fullscreen."))
    (other-window 1)
    (redisplay)))

(defun doc-present-create-presenter-frame ()
  (let ((st doc-present--st))
    (switch-to-buffer (get-buffer-create doc-present-presenter-buffer-name))
    (doc-present-draw-presenter-frame)
    (doc-present-mode)))

(defun doc-present-draw-presenter-frame ()
  (unless (buffer-live-p (get-buffer doc-present-presenter-buffer-name))
    (user-error "Presenter buffer was deleted. Restart presentation."))
  (with-current-buffer doc-present-presenter-buffer-name
    (setq buffer-read-only nil)
    (erase-buffer)
    (save-excursion (insert doc-present-presenter-layout))
    (dolist (cur doc-present-presenter-widgets)
      (save-excursion
	(when (search-forward (car cur) nil t)
	  (delete-region (match-beginning 0) (match-end 0))
	  (funcall (cadr cur)))))
    (goto-char (point-max))))

(defun doc-present-insert-current-slide-image ()
  (doc-present-insert-slide (doc-present-status-current doc-present--st)
			    doc-present-current-slide-width 10))

(defun doc-present-insert-next-slide-image ()
  (if (= (doc-present-status-current doc-present--st)
	 (doc-present-status-max doc-present--st))
      (insert "Last slide")
    (doc-present-insert-slide (1+ (doc-present-status-current doc-present--st))
			      doc-present-next-slide-width 10)))

(defun doc-present-insert-slide (number width &optional margin relief)
  (let ((file
	 (expand-file-name (format "page-%d.png" number)
			   (doc-present-status-cachedir doc-present--st))))
    (insert-image
     (create-image file 'imagemagick nil :width width
		   :margin (or margin 0) :relief (or relief 0)))))

(defun doc-present-insert-clock ()
  (let ((ov (make-overlay (point) (1+ (point)))))
    (setf (doc-present-status-clock-overlay doc-present--st) ov)
    (overlay-put ov 'display
		 (propertize
		  (format-time-string doc-present-clock-time-format (current-time))
		  'face 'doc-present-clock-face))
    (unless doc-present--clock-timer
      (setq doc-present--clock-timer
	    (run-at-time t 1 'doc-present-update-clock)))))

(defun doc-present-update-clock ()
  (let ((ov (doc-present-status-clock-overlay doc-present--st))
	(warntext "Warning: Presenter frame does not have focus."))
    (when (and ov
	       (buffer-live-p (get-buffer doc-present-presenter-buffer-name)))
      (with-current-buffer (get-buffer doc-present-presenter-buffer-name)
	(overlay-put ov 'display
		     (propertize
		      (format-time-string doc-present-clock-time-format (current-time))
		      'face 'doc-present-clock-face))))
    ;; Also warn if mouse is not in presenter frame
    (if (or (not (eq (car (mouse-position)) (doc-present-status-pframe doc-present--st)))
	    (not (eq (selected-frame) (doc-present-status-pframe doc-present--st))))
	(message warntext)
      (when (string-match-p warntext (current-message))
	(message nil)))))

(defun doc-present-insert-stopwatch ()
  (let* ((ov (make-overlay (point) (1+ (point))))
	 (seconds (doc-present-status-seconds doc-present--st)))
    (setf (doc-present-status-seconds-overlay doc-present--st) ov)
    (overlay-put ov 'display
		 (propertize
		  (format-seconds doc-present-stopwatch-format seconds)
		  'face 'doc-present-stopwatch-face))))

(defun doc-present-insert-current-slide-number ()
  (let ((number (doc-present-status-current doc-present--st)))
    (insert (propertize (number-to-string number)
			'face 'doc-present-slide-number-face))))

(defun doc-present-insert-max-slide-number ()
  (insert (propertize (number-to-string
		       (doc-present-status-max doc-present--st))
		      'face 'doc-present-slide-number-face)))

(defun doc-present-insert-org-notes ()
  (let ((notes (doc-present-status-notes doc-present--st))
	(current (doc-present-status-current doc-present--st))
	found cur)
    (when notes
      (while (setq cur (car notes))
	(if (or (= current (caar cur))
		(and (> current (caar cur))
		     (<= current (cdar cur))))
	    (setq found cur
		  notes nil)
	  (setq notes (cdr notes))))
      (when found
	(insert (propertize (cadr found) 'face 'doc-present-notes-face))))))

(defun doc-present-parse-org-headlines ()
  (org-narrow-to-subtree)
  (when (looking-at "^[*]+\\s-*\\([0-9]+\\)\\s-*\\(?:-\\s-*\\([0-9]+\\)\\)?")
    (let* ((first (match-string-no-properties 1))
	   (second (or (match-string-no-properties 2) first))
	   (text (progn (forward-line)
			(buffer-substring-no-properties (point) (point-max)))))
      (widen)
      `(,(cons (string-to-number first)
	       (string-to-number second)) ,text))))

(defun doc-present-snarf-notes-from-orgfile ()
  (let* ((filename (concat (file-name-sans-extension
			    (doc-present-status-filename doc-present--st))
			   "-notes.org")))
    (if (file-exists-p filename)
	(with-current-buffer (find-file-noselect filename)
	  (setf (doc-present-status-notes doc-present--st)
		(org-map-entries 'doc-present-parse-org-headlines)))
      (setf (doc-present-status-notes doc-present--st) nil))))

(defun doc-present-quit ()
  (interactive)
  (when (y-or-n-p "Really quit presentation?")
    (when (framep (doc-present-status-sframe doc-present--st))
      (delete-frame (doc-present-status-sframe doc-present--st)))
    (kill-buffer doc-present-presenter-buffer-name)
    (kill-buffer doc-present-slide-buffer-name)
    (when (timerp doc-present--clock-timer)
      (cancel-timer doc-present--clock-timer))
    (when (timerp doc-present--stopwatch-timer)
      (cancel-timer doc-present--stopwatch-timer))))

(defun doc-present-help-mode ()
  (interactive)
  (kill-all-local-variables)
  (setq major-mode 'doc-present-help-mode)
  (setq mode-name "doc-present-help")
  (set-syntax-table text-mode-syntax-table)
  (use-local-map doc-present-help-mode-map)
  (setq buffer-read-only t))

(defvar doc-present-help-mode-map
  (let ((map (make-keymap)))
    (define-key map [(q)] 'doc-present-help-quit)
    map)
  "")

(defun doc-present-help ()
  (interactive)
  (select-window (split-window-horizontally -70))
  (switch-to-buffer "*doc-present-help*")
  (insert doc-present-help-text)
  (doc-present-help-mode))

(defun doc-present-help-quit ()
  (interactive)
  (kill-buffer "*doc-present-help*")
  (delete-window))

(defun doc-present-toggle-black-out ()
  (interactive)
  (unless (frame-live-p (doc-present-status-sframe doc-present--st))
    (user-error "No slide frame available (create a new one with 'm')"))
  (doc-present-ensure-full-slide-window)
  (with-selected-frame (doc-present-status-sframe doc-present--st)
    (set-buffer doc-present-slide-buffer-name)
    (setq buffer-read-only nil)
    (if (= (point-min) (point-max))
	(doc-present-update-main-slide)
      (erase-buffer)
      (set-background-color "black"))
    (setq buffer-read-only t)))

(defun doc-present-toggle-stopwatch ()
  (interactive)
  (if doc-present--stopwatch-timer
      (progn
	(cancel-timer doc-present--stopwatch-timer)
	(message "Stopwatch stopped")
	(setq doc-present--stopwatch-timer nil))
    (setq doc-present--stopwatch-timer
	  (run-at-time t 1 'doc-present-update-stopwatch))
    (message "Stopwatch started")))

(defun doc-present-update-stopwatch ()
  (let ((ov (doc-present-status-seconds-overlay doc-present--st))
	(seconds (incf (doc-present-status-seconds doc-present--st))))
    (when (and ov
	       (buffer-live-p (get-buffer doc-present-presenter-buffer-name)))
      (with-current-buffer (get-buffer doc-present-presenter-buffer-name)
	(overlay-put ov 'display
		     (propertize
		      (format-seconds doc-present-stopwatch-format seconds)
		      'face 'doc-present-stopwatch-face))))))

(defvar doc-present--prerender-workload nil)
(defvar doc-present--prerender-timer nil)
(defun doc-present-create-slide-cache ()
  (interactive)
  (message "Starting to create slide cache")
  (setq doc-present--prerender-workload nil)
  (with-selected-frame (doc-present-status-pframe doc-present--st)
    (setf (doc-present-status-renderwin doc-present--st)
	  (split-window-horizontally -15)))
  (unless (frame-live-p (doc-present-status-sframe doc-present--st))
    (user-error "No slide frame available (create a new one with 'm')"))
  (unless (eq (frame-parameter (doc-present-status-sframe doc-present--st)
			       'fullscreen) 'fullboth)
    (user-error "Maximize slide frame on presentation projector first"))
  (dolist (i (number-sequence 1 (doc-present-status-max doc-present--st)))
    (setq doc-present--prerender-workload
	  (append
	   doc-present--prerender-workload
	   `((,i ,(doc-present-status-slide-size doc-present--st))
	     (,i ,(cons :width doc-present-current-slide-width))
	     (,i ,(cons :width doc-present-next-slide-width))))))
  (setq doc-present--prerender-timer
	(run-with-idle-timer 1 1 'doc-present-prerender-slides)))

;; Caching only happens for a frame, so this is pointless...
(defun doc-present-prerender-slides ()
  (if (null doc-present--prerender-workload)
      (progn
	(message "Slide cache creation finished")
	(when (window-live-p (doc-present-status-renderwin doc-present--st))
	  (delete-window (doc-present-status-renderwin doc-present--st)))
	(kill-buffer "*doc-present-prerender*")
	(cancel-timer doc-present--prerender-timer))
    (let (current size)
      (catch 'exit
	(while (setq current (pop doc-present--prerender-workload))
	  (setq size (cadr current))
	  (unless (window-live-p (doc-present-status-renderwin doc-present--st))
	    (message "Prerender window not visible. Canceling cache creation.")
	    (cancel-timer doc-present--prerender-timer))
	  (with-selected-window (doc-present-status-renderwin doc-present--st)
	  (switch-to-buffer (get-buffer-create "*doc-present-prerender*"))
	    (erase-buffer)
	  (insert-image
	   (create-image
	    (expand-file-name
	     (format "page-%d.png" (car current))
	     (doc-present-status-cachedir doc-present--st))
	    'imagemagick nil (car size) (cdr size)))
	    (redisplay t)
	    (when (input-pending-p)
	      (throw 'exit nil))))))))

(defun doc-present-select-presenter-frame ()
  "Make sure we are on the presenter frame."
  (unless (eq (selected-frame) (doc-present-status-pframe doc-present--st))
    (select-frame (doc-present-status-pframe doc-present--st))))

(defun doc-present-toggle-fullscreen ()
  (interactive)
  (unless (frame-live-p (doc-present-status-sframe doc-present--st))
    (user-error "No slide frame available (create a new one with 'm')"))
  (with-selected-frame (doc-present-status-sframe doc-present--st)
    (if (eq (frame-parameter nil 'fullscreen) 'fullboth)
	(progn
	  ;; switch back from fullscreen
	  (message "Switching back")
	  (modify-frame-parameters nil '((fullscreen . nil)))
	  (let ((oldface (doc-present-status-oldface doc-present--st))
		(oldsize (doc-present-status-oldsize doc-present--st)))
	    (set-face-attribute 'default (selected-frame)
				:family (car oldface) :height (cdr oldface))
	    (message "Restoring image width/height %d %d" (car oldsize) (cdr oldsize))
	    (modify-frame-parameters nil `((width . ,(car oldsize))
					   (height . ,(cdr oldsize))))))
      ;; switch to fullscreen
      (message "Switch to fullscreen")
      (setf (doc-present-status-oldsize doc-present--st)
	    (cons (frame-parameter nil 'width)
		  (frame-parameter nil 'height)))
      (delete-other-windows)
      (modify-frame-parameters nil '((fullscreen . fullboth)))
      (redisplay t)
      (set-face-attribute
       'default (selected-frame)
       :family (face-attribute 'doc-present-tiny-xft-font :family)
       :height (face-attribute 'doc-present-tiny-xft-font :height))
      (redisplay t)
      (set-cursor-color doc-present-slide-frame-background-color)
      (set-background-color doc-present-slide-frame-background-color)
      (setf (doc-present-status-slide-max-size doc-present--st)
	    (cons (frame-pixel-width) (frame-pixel-height))))
    (if (get-buffer-window doc-present-overview-buffer-name)
	(doc-present-overview-on-slide-frame)
      (doc-present-update-main-slide))))

(defun doc-present-presentation-start ()
  (interactive)
  (with-selected-frame (doc-present-status-sframe doc-present--st)
    (set-face-attribute
     'default (selected-frame)
     :family (face-attribute 'doc-present-tiny-xft-font :family)
     :height (face-attribute 'doc-present-tiny-xft-font :height))
    (set-cursor-color doc-present-slide-frame-background-color)
    (set-background-color doc-present-slide-frame-background-color)
    (modify-frame-parameters nil '((fullscreen . fullboth)))
    (redisplay t)
    (with-current-buffer doc-present-slide-buffer-name
      (setq buffer-read-only nil)
      (goto-char (point-min))
      (delete-region (point) (1+ (point-at-eol)))
      (goto-char (point-max))
      (let ((disp (get-text-property (point-min) 'display)))
	(setcdr disp (plist-put
		      (cdr disp) :width (frame-pixel-width)))
	(setcdr disp (plist-put
		      (cdr disp)
		      :height (frame-pixel-height)))
	(put-text-property (point-min) (1+ (point-min))
			   'display
			   disp))
      (setq buffer-read-only t)))
  (select-frame (doc-present-status-pframe doc-present--st)))

(defun doc-present-next-slide ()
  (interactive)
  (if (= (doc-present-status-current doc-present--st)
	 (doc-present-status-max doc-present--st))
      (message "Already on last slide.")
  (incf (doc-present-status-current doc-present--st))
  (doc-present-select-presenter-frame)
  (doc-present-draw-presenter-frame)
  (doc-present-update-main-slide)))

(defun doc-present-previous-slide ()
  (interactive)
  (if (= (doc-present-status-current doc-present--st) 1)
      (message "Already on first slide.")
    (decf (doc-present-status-current doc-present--st))
    (doc-present-select-presenter-frame)
    (doc-present-draw-presenter-frame)
    (doc-present-update-main-slide)))

(defun doc-present-ensure-full-slide-window ()
  (if (not (frame-live-p (doc-present-status-sframe doc-present--st)))
      (message "Slide frame was deleted (hit 'm' to create a new one)")
    (with-selected-frame (doc-present-status-sframe doc-present--st)
      (let ((slidewin (get-buffer-window doc-present-slide-buffer-name)))
	(unless (and (window-full-width-p slidewin)
		     (window-full-height-p slidewin))
	  (with-selected-window slidewin
	    (delete-other-windows)))))))

(defun doc-present-update-main-slide (&optional use-window-size)
  (if (not (frame-live-p (doc-present-status-sframe doc-present--st)))
      (message "Slide frame was deleted (hit 'm' to create a new one)")
    (let* ((number (doc-present-status-current doc-present--st))
	   (cachedir (doc-present-status-cachedir doc-present--st))
	   (file
	    (expand-file-name
	     (format "page-%d.png" number) cachedir))
	   width height props)
      (doc-present-ensure-full-slide-window)
      (if use-window-size
	  (with-selected-window
	      (get-buffer-window doc-present-slide-buffer-name)
	    (let ((edges (window-inside-pixel-edges)))
	      (setq width (- (nth 2 edges) (car edges))
		    height (- (nth 3 edges) (nth 1 edges)))))
	(with-selected-frame (doc-present-status-sframe doc-present--st)
	  (set-background-color doc-present-slide-frame-background-color)
	  (setq width (frame-pixel-width)
		height (frame-pixel-height))))
      (with-current-buffer (get-buffer doc-present-slide-buffer-name)
	(setq buffer-read-only nil)
	(erase-buffer)
	(if (> (/ (float width) height)
	       (doc-present-status-aspect doc-present--st))
	    (progn
	      (setq props
		    (plist-put props :height height))
	      (setf (doc-present-status-slide-size doc-present--st)
		    (cons :height height)))
	  (setq props
		(plist-put props :width width))
	  (setf (doc-present-status-slide-size doc-present--st)
		(cons :width width)))
	(insert-image
	 (apply 'create-image file 'imagemagick nil props))
	(setq buffer-read-only t)))))

;;; Slide Overview

;; Internal variables

(defvar doc-present-overview-columns nil)
(defvar doc-present-overview-lines nil)
(defvar doc-present-overview-old-image 0)
(defvar doc-present-overview-current-image 1)
(defvar doc-present-overview-max-number 0)
(defvar doc-present-overview-image-positions nil)

;; Code

(defun doc-present-overview ()
  (interactive)
  (select-frame (doc-present-status-pframe doc-present--st))
  (if (eq major-mode 'doc-present-overview-mode)
      (doc-present-overview-on-slide-frame)
    (doc-present-overview-page)))

(defun doc-present-overview-page ()
  (let* ((cachedir (doc-present-status-cachedir doc-present--st))
	 (numpages (doc-present-status-max doc-present--st))
	 (edges (window-inside-pixel-edges))
	 (windowwidth (- (nth 2 edges) (car edges)))
	 (charwidth (frame-char-width))
	 (counter 1)
	 file)
    (when (eq (frame-parameter nil 'fullscreen) 'fullboth)
      (setq windowwidth (car (doc-present-status-slide-max-size doc-present--st))))
    (setq doc-present-overview-columns
	  (round (/ windowwidth
		    (+ doc-present-overview-image-width 30))))
    (setq doc-present-overview-image-positions
	  (make-vector (1+ numpages) 0))
    (switch-to-buffer  (get-buffer-create doc-present-overview-buffer-name))
    (setq buffer-read-only nil
	  doc-present-overview-old-image 0)
    (erase-buffer)
    (doc-present-overview-insert-numbers 1 doc-present-overview-columns)
    (while (< counter numpages)
      (setq file (expand-file-name (format "page-%d.png" counter)
				   cachedir))
      (aset doc-present-overview-image-positions counter (point))
      (insert-image
       (create-image file 'imagemagick nil
		     :width doc-present-overview-image-width
		     :margin charwidth
		     :relief 0))
      (when (zerop (mod counter doc-present-overview-columns))
	(insert "\n")
	(redisplay t)
	(doc-present-overview-insert-numbers
	 (1+ counter) (min (+ counter doc-present-overview-columns)
			   (1- numpages))))
      (setq counter (1+ counter)))
    (doc-present-overview-mode)
    (setq doc-present-overview-lines (line-number-at-pos))
    (goto-char (point-min))
    (forward-line)
    (doc-present-overview-maybe-raise)
    (setq doc-present-overview-current-image 1
	  doc-present-overview-max-number numpages)))

(defun doc-present-overview-insert-numbers (from to)
  (let* ((charwidth (frame-char-width))
	 (chars-per-image (+ (/ doc-present-overview-image-width charwidth) 2))
	 (tab-stop-list (number-sequence (/ chars-per-image 2) 1000
					 chars-per-image)))
    (mapc
     (lambda (num)
       (tab-to-tab-stop)
       (insert (number-to-string num)))
     (number-sequence from to))
    (insert "\n")))

(defvar doc-present-overview-mode-map)
(defun doc-present-overview-mode ()
  (interactive)
  (kill-all-local-variables)
  (setq major-mode 'doc-present-overview-mode)
  (setq mode-name "doc-present-overview")
  (set-syntax-table text-mode-syntax-table)
  (use-local-map doc-present-overview-mode-map)
  (setq buffer-read-only t))

(defvar doc-present-overview-mode-map
  (let ((map (make-keymap)))
    (define-key map [(right)] 'doc-present-overview-right)
    (define-key map [(left)] 'doc-present-overview-left)
    (define-key map [(up)] 'doc-present-overview-up)
    (define-key map [(down)] 'doc-present-overview-down)
    (define-key map [(o)] 'doc-present-overview-on-slide-frame)
    (define-key map [(return)] 'doc-present-overview-show-slide)
    (define-key map (kbd "SPC") 'doc-present-overview-show-slide-and-quit)
    (define-key map [(f)] 'doc-present-toggle-fullscreen)
    (define-key map [(q)] 'doc-present-overview-quit)
    map)
  "")

(defun doc-present-overview-show-slide ()
  (interactive)
  (setf (doc-present-status-current doc-present--st)
	doc-present-overview-current-image)
  (doc-present-update-main-slide))

(defun doc-present-overview-quit ()
  (interactive)
  (kill-buffer))

(defun doc-present-overview-show-slide-and-quit ()
  (interactive)
  (doc-present-overview-show-slide)
  (doc-present-overview-quit)
  (with-selected-frame (doc-present-status-pframe doc-present--st)
    (when (buffer-live-p (get-buffer doc-present-presenter-buffer-name))
      (switch-to-buffer (get-buffer doc-present-presenter-buffer-name))
      (delete-other-windows))
    (doc-present-draw-presenter-frame)))

(defun doc-present-overview-on-slide-frame ()
  (interactive)
  (let ((bc (frame-parameter (doc-present-status-pframe doc-present--st)
			     'background-color)))
    (with-selected-frame (doc-present-status-sframe doc-present--st)
      (let ((oldface (doc-present-status-oldface doc-present--st)))
	(set-face-attribute 'default (selected-frame)
			    :family (car oldface) :height (cdr oldface))
	(set-background-color bc)
	(set-frame-parameter nil 'cursor-type 'box))
      (redisplay t)
      (switch-to-buffer doc-present-overview-buffer-name)
      (doc-present-overview-page)
      (goto-char (point-min))
      (forward-line)
      (setq mode-line-format nil)
      (set-window-start nil (point-min)))
    (with-selected-frame (doc-present-status-pframe doc-present--st)
      (with-current-buffer doc-present-overview-buffer-name
	(goto-char (point-min))
	(forward-line)
	(doc-present-overview-maybe-raise)))))

(defun doc-present-overview-right ()
  (interactive)
  (unless (or (= (current-column) (1- doc-present-overview-columns))
	      (>= (1+ doc-present-overview-current-image)
		  doc-present-overview-max-number))
    (forward-char)
    (doc-present-overview-sync-frames)
    (setq doc-present-overview-current-image
	  (1+ doc-present-overview-current-image))
    (doc-present-overview-maybe-raise)))

(defun doc-present-overview-left ()
  (interactive)
  (unless (= (current-column) 0)
    (forward-char -1)
    (doc-present-overview-sync-frames)
    (setq doc-present-overview-current-image
	  (1- doc-present-overview-current-image))
    (doc-present-overview-maybe-raise)))

(defun doc-present-overview-up ()
  (interactive)
  (unless (= (line-number-at-pos) 2)
    (setq doc-present-overview-current-image
	  (- doc-present-overview-current-image
	     doc-present-overview-columns))
    (goto-char (aref doc-present-overview-image-positions
		     doc-present-overview-current-image))
    (doc-present-overview-sync-frames)
    (doc-present-overview-maybe-raise)))

(defun doc-present-overview-down ()
  (interactive)
  (unless (>= (+ doc-present-overview-current-image
		 doc-present-overview-columns)
	      doc-present-overview-max-number)
    (setq doc-present-overview-current-image
	  (+ doc-present-overview-current-image
	     doc-present-overview-columns))
    (goto-char (aref doc-present-overview-image-positions
		     doc-present-overview-current-image))
    (doc-present-overview-sync-frames)
    (doc-present-overview-maybe-raise)))

(defun doc-present-overview-sync-frames ()
  (let ((pt (point)))
    (if (eq (selected-frame)
	    (doc-present-status-sframe doc-present--st))
	(with-selected-frame (doc-present-status-pframe doc-present--st)
	  (goto-char pt))
      (with-selected-frame (doc-present-status-sframe doc-present--st)
	(goto-char pt)))))

(defun doc-present-overview-maybe-raise ()
  (unless (= (point) doc-present-overview-old-image)
    (let ((disp (get-text-property (point) 'display)))
      (with-silent-modifications
	(when (eq (car disp) 'image)
	  (setcdr disp (plist-put (cdr disp) :margin 4))
	  (setcdr disp (plist-put (cdr disp) :relief 4))
	  (set-text-properties (point) (1+ (point)) `(display ,disp))
	  (when (not (zerop doc-present-overview-old-image))
	    (setq disp (get-text-property doc-present-overview-old-image 'display))
	    (setcdr disp (plist-put (cdr disp) :margin 8))
	    (setcdr disp (plist-put (cdr disp) :relief 0))
	    (set-text-properties doc-present-overview-old-image
				 (1+ doc-present-overview-old-image) `(display ,disp)))
	  (setq doc-present-overview-old-image (point)))))))

(provide 'doc-present)

;; doc-present.el ends here
