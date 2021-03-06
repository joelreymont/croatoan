(in-package :de.anvi.croatoan)

;;; Define all macros here centrally.

(defmacro with-screen ((screen &key
                               (bind-debugger-hook t)
                               (input-buffering nil)
                               (process-control-chars t)
                               (enable-newline-translation t)
                               (input-blocking t)
                               (input-echoing t)
                               (enable-function-keys t)
                               (enable-scrolling nil)
                               (insert-mode nil)
                               (enable-colors t)
                               (use-terminal-colors nil)
                               (cursor-visible t)
                               (stacked nil)
                               (fgcolor nil)
                               (bgcolor nil)
                               (color-pair nil)
                               (background nil))
                       &body body)
  "Create a screen, evaluate the forms in the body, then cleanly close the screen.

Pass any arguments besides BIND-DEBUGGER-HOOK to the initialisation of the
screen object. The screen is cleared immediately after initialisation.

This macro will bind *DEBUGGER-HOOK* so that END-SCREEN gets called before the
condition is printed. This will interfere with SWANK as it also binds *DEBUGGER-HOOK*.
To prevent WITH-SCREEN from binding *DEBUGGER-HOOK*, set BIND-DEBUGGER-HOOK to NIL.

This macro is the main entry point for writing ncurses programs with the croatoan
library. Do not run more than one screen at the same time."
  `(unwind-protect
        (let ((,screen (make-instance 'screen
                                      :input-buffering ,input-buffering
                                      :process-control-chars ,process-control-chars
                                      :enable-newline-translation ,enable-newline-translation
                                      :input-blocking ,input-blocking
                                      :input-echoing ,input-echoing
                                      :enable-function-keys ,enable-function-keys
                                      :enable-scrolling ,enable-scrolling
                                      :insert-mode ,insert-mode
                                      :enable-colors ,enable-colors
                                      :use-terminal-colors ,use-terminal-colors
                                      :cursor-visible ,cursor-visible
                                      :stacked ,stacked
                                      :fgcolor ,fgcolor
                                      :bgcolor ,bgcolor
                                      :color-pair ,color-pair
                                      :background ,background))

              ;; when an error is signaled and not handled, cleanly end ncurses, print the condition text
              ;; into the repl and get out of the debugger into the repl.
              ;; the debugger is annoying with ncurses apps.
              ;; add (abort) to automatically get out of the debugger.
              ;; this binding is added by default. call with-screen with :bind-debugger-hook nil to remove.
              ,@(if bind-debugger-hook
                  '((*debugger-hook* #'(lambda (c h)
                                         (declare (ignore h))
                                         (end-screen)
                                         (print c))))
                  nil))

          ;; clear the display when starting up.
          (clear ,screen)

          ,@body)

     ;; cleanly exit ncurses whatever happens.
     (end-screen)))

(defmacro with-window ((win &rest options) &body body)
  "Create a window, evaluate the forms in the body, then cleanly close the window.

Pass any arguments to the initialisation of the window object.

Example:

(with-window (win :input-echoing t
  body)"
  `(let ((,win (make-instance 'window ,@options)))
     (unwind-protect
          (progn
            ,@body)
       (close ,win))))

;; see similar macro cffi:with-foreign-objects.
(defmacro with-windows (bindings &body body)
  "Create one or more windows, evaluate the forms in the body, then cleanly close the windows.

Pass any arguments to the initialisation of the window objects.

Example:

(with-windows ((win1 :input-echoing t)
               (win2 :input-echoing t))
  body)"
  (if bindings
      ;; execute the bindings recursively
      `(with-window ,(car bindings)
         ;; the cdr is the body
         (with-windows ,(cdr bindings)
           ,@body))
      ;; finally, execute the body.
      `(progn
         ,@body)))

(defmacro event-case ((window event &optional mouse-y mouse-x) &body body)
  "Window event loop, events are handled by an implicit case form.

For now, it is limited to events generated in a single window. So events
from multiple windows have to be handled separately.

In order for event handling to work, input-buffering has to be nil.
Several control character events can only be handled when 
process-control-chars is also nil.

If input-blocking is nil, we can handle the (nil) event, i.e. what
happens between key presses.

If input-blocking is t, the (nil) event is never returned.

The main window event loop name is hard coded to event-case to be
used with return-from.

Instead of ((nil) nil), which eats 100% CPU, use input-blocking t."
  ;; depending on which version of ncurses is loaded, decide which event reader to use.
  (let ((get-event-function
         #+(or sb-unicode unicode openmcl-unicode-strings) ''get-wide-event
         #-(or sb-unicode unicode openmcl-unicode-strings) ''get-event))
    (if (and mouse-y mouse-x)
        ;; when the variables y and x are passed, bind them to the mouse coordinates
        `(loop :named event-case do
            (multiple-value-bind (,event ,mouse-y ,mouse-x) (funcall ,get-event-function ,window)
              ;;(print (list ,event mouse-y mouse-x) ,window)
              (when (null ,event)
                ;; process the contents of the job queue (ncurses access from other threads)
                (process))
              (case ,event
                ,@body)))
        ;; default case, no mouse used
        `(loop :named event-case do
            (let ((,event (funcall ,get-event-function ,window)))
              (when (null ,event)
                ;; process the contents of the job queue (ncurses access from other threads)
                (process))
              (case ,event
                ,@body))))))

(defun bind (object event handler)
  "Bind the handler function to the event in the bindings alist of the object.

The object can be a croatoan object (like window or form) or a keymap.

If event is a list of events, bind the handler to each event separately.

The handlers will be called by the run-event-loop when keyboard or mouse events occur.

The handler functions have two mandatory arguments, window and event.

For every event-loop, at least an event to exit the event loop should be assigned,
by associating it with the predefined function exit-event-loop.

If a handler for the default event t is defined, it will handle all events for which
no specific event handler has been defined.

If input-blocking of the window is set to nil, a handler for the nil event
can be defined, which will be called at a specified frame-rate between keypresses.
Here the main application state can be updated.

Alternatively, to achieve the same effect, input-blocking can be set to a specific
delay in miliseconds.

Example use: (bind scr #\q  (lambda (win event) (throw 'event-loop :quit)))"
  (with-accessors ((bindings bindings)) object
    (cond ((or (null event)
               (atom event))
           (if (stringp event)
               ;; when event is a control char in caret notation, i.e. "^A"
               (setf bindings (acons (string-to-char event) handler bindings))
               (setf bindings (acons event handler bindings))))
          ((listp event)
           (dolist (e event)
             (if (stringp e)
                 (setf bindings (acons (string-to-char e) handler bindings))
                 (setf bindings (acons e handler bindings))))))))

(defun unbind (object event)
  "Remove the event and the handler function from object's bindings alist.

If event is a list of events, remove each event separately from the alist."
  (with-accessors ((bindings bindings)) object
    (cond ((or (null event)
               (atom event))
           (if (stringp event)
               ;; when event is a control char in caret notation, i.e. "^A"
               (setf bindings (remove (string-to-char event) bindings :key #'car))
               (setf bindings (remove event bindings :key #'car))))
          ((listp event)
           (dolist (e event)
             (if (stringp e)
                 (setf bindings (remove (string-to-char e) bindings :key #'car))
                 (setf bindings (remove e bindings :key #'car))))))))

(defparameter *keymaps* nil "An alist of available keymaps.")

(defmacro define-keymap (name &body body)
  "A convenience macro to register a keymap given its name and (key function) pairs.

As with bind, the keys can be characters, two-char strings in caret notation for
control chars and keywords for function keys."
  `(progn
     (setf *keymaps* (acons ',name (make-instance 'keymap) *keymaps*))
     (%defcdr (bindings (cdr (assoc ',name *keymaps*))) ,@body)))

;; take an alist and populate it with key-value pairs given in the body
(defmacro %defcdr (alist &body body)
  (when (car body)
    `(progn
       (%defcar ,alist ,(car body))
       (%defcdr ,alist ,@(cdr body)))))

;; add a single key-value cons to the alist
;; convert symbols to function objects
;; convert caret notation strings to control chars
(defmacro %defcar (alist (k v))
  `(cond ((and (symbolp ,v) (fboundp ,v))
          (if (stringp ,k)
              (push (cons (string-to-char ,k) (fdefinition ,v)) ,alist)
              (push (cons ,k (fdefinition ,v)) ,alist)))
         ((functionp ,v)
          (if (stringp ,k)
              (push (cons (string-to-char ,k) ,v) ,alist)
              (push (cons ,k ,v) ,alist)))
         (t
          (error "binding neither symbol nor function"))))

(defun find-keymap (keymap-name)
  "Return a keymap given by its name from the global keymap alist."
  (cdr (assoc keymap-name *keymaps*)))

;; source: alexandria
(defun plist2alist (plist)
  "Take a plist in the form (k1 v1 k2 v2 ...), return an alist ((k1 . v1) (k2 . v2) ...)"
  (let (alist)
    (do ((lst plist (cddr lst)))
        ((endp lst) (nreverse alist))
      (push (cons (car lst) (cadr lst)) alist))))

(defun get-event-handler (object event)
  "Take an object and an event, return the object's handler for that event.

The key bindings alist is stored in the bindings slot of the object.

An external keymap can be defined so several objects can share the same
set of bindings.

Object-local bindings override the external keymap. The local bindings
are checked first for a handler, then the external keymap.

If no handler is defined for the event, the default event handler t is tried.
If not even a default handler is defined, the event is ignored.

If input-blocking is nil, we receive nil events in case no real events occur.
In that case, the handler for the nil event is returned, if defined.

The event pairs are added by the bind function as conses: (event . #'handler).

An event should be bound to the pre-defined function exit-event-loop."
  (flet ((ev (event)
           (let ((keymap (typecase (keymap object)
                           ;; the keymap can be a keymap object directly
                           (keymap (keymap object))
                           ;; or a symbol as the name of the keymap
                           (symbol (find-keymap (keymap object))))))
             ;; object-local bindings override the external keymap
             ;; an event is checked in the bindings first, then in the external keymap.
             (if (bindings object)
                 (if (assoc event (bindings object))
                     (assoc event (bindings object))
                     ;; if there is no handler in the local bindings,
                     ;; check if there is a keymap
                     (if (and keymap (bindings keymap))
                         (assoc event (bindings keymap))
                         nil))
                 ;; if there are no local bindings, check the external keymap
                 (if (and keymap (bindings keymap))
                     (assoc event (bindings keymap))
                     nil)))))
    (cond
      ;; Event occured and event handler is defined.
      ((and event (ev event)) (cdr (ev event)))
      ;; Event occured and a default event handler is defined.
      ;; If not even the default handler is defined, the event is ignored.
      ((and event (ev t)) (cdr (ev t)))
      ;; If no event occured and the idle handler is defined.
      ;; The event is only nil when input input-blocking is nil.
      ((and (null event) (ev nil)) (cdr (ev nil)))
      ;; If no event occured and the idle handler is not defined.
      (t nil))))

(defun run-event-loop (object &rest args)
  "Read events from the window, then call predefined event handler functions on the events.

The handlers can be added by the bind function, or by directly setting a predefined keymap
to the window's bindings slot.

Args is one or more additional arguments passed to the handlers.

Provide a non-local exit point so we can exit the loop from an event handler. 

One of the events must provide a way to exit the event loop by throwing 'event-loop.

The function exit-event-loop is pre-defined to perform this non-local exit."
  (catch object
    (loop
       (let* ((window (typecase object
                        (form-window (sub-window object))
                        ;; if the object is a window
                        (window object)
                        ;; if the object isnt a window, it should have an associated window.
                        (otherwise (window object))))
              (event (get-wide-event window)))
         (handle-event object event args)
         ;; process the contents of the job queue (ncurses access from other threads)
         (process)
         ;; should a frame rate be a property of the window or of the object?
         (when (and (null event) (frame-rate window))
           (sleep (/ 1.0 (frame-rate window)))) ))))

(defgeneric handle-event (object event args)
  ;; the default method applies to window, field, button, menu.
  (:method (object event args)
    "Default method for all objects without a specialized method."
    (let ((handler (get-event-handler object event)))
      (when handler
        ;; if args is nil, apply will call the handler with just object and event
        ;; this means that if we dont need args, we can define most handlers as two-argument functions.
        (apply handler object event args)))))

(defmethod handle-event ((form form) event args)
  "If a form can't handle an event, let the current form element try to handle it."
  (let ((handler (get-event-handler form event)))
    (if handler
        (apply handler form event args)
        (handle-event (current-element form) event args))))

(defun exit-event-loop (object event &rest args)
  "Associate this function with an event to exit the event loop."
  (declare (ignore win event args))
  (throw object :exit-event-loop))

(defmacro save-excursion (window &body body)
  "After executing body, return the cursor in window to its initial position."
  (let ((pos (gensym)))
    `(let ((,pos (cursor-position ,window)))
       ,@body
       (move ,window (car ,pos) (cadr ,pos)))))
