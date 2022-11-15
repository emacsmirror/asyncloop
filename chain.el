;;; chain.el --- non-blocking threads, if by thread you mean list of functions -*- lexical-binding: t -*-

;; Copyright (C) 2022 Martin Edström

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;; Author:  <meedstrom@teknik.io>
;; Created: 2022-10-30
;; Version: 0.1.0
;; Keywords: tools
;; Homepage: https://github.com/meedstrom/chain
;; Package-Requires: ((emacs "28.1") (named-timer "0.1"))

;;; Commentary:

;; Ok, say you have a big slow function, and you decide to carve it up into
;; piecemeal functions each with imperceptible latency.  How will you run those
;; functions?  Through a dolist?  No, because dolists can't be paused, so that'd
;; be the same as the big slow function.  You need something smart... something
;; perhaps utilizing `run-with-idle-timer'...
;;
;; This library uses builtin timers to help you run a series of functions, we'll
;; call it a chain, without blocking Emacs.  Same principle as deferred.el, but
;; simpler if you're unfamiliar with jsdeferred or its other inspiration sources.
;;
;; Features:
;;
;; - it weeds out many edge cases for you -- rolling your own timer-based
;;   non-blocking mechanism is surprisingly complicated
;;
;; - it gets out of the way when the user is operating Emacs & should be
;;   unnoticable
;;
;; - it begins executing instantly, not, say, after a second of idle time,
;;   because a second can be all the time you get in the first place, e.g. the
;;   time between when user switches to minibuffer and when user begins to type.
;;
;; The end user API consists mainly of `chain-define' and `chain-run'.
;; Sometimes, user may also find reason to call `chain-state' and `chain-echo'.
;; For example usage, see deianira.el.

;;; Code:

(require 'cl-lib)
(require 'named-timer) ;; prevent bugs every day with this 70-line library

(defvar chain-debug nil
  "Whether to make available a buffer of debug messages.")

(defun chain--debug-buffer ()
  "Buffer to write debug messages to."
  (let ((bufname (concat (unless chain-debug " ") "*Chain.el debug*")))
    (or (get-buffer bufname)
        (with-current-buffer (get-buffer-create bufname)
          (setq-local truncate-lines t)
          (setq-local buffer-read-only nil)
          (current-buffer)))))

(defun chain-echo (&rest args)
  "Write a message to the debug buffer.
Arguments ARGS same as for `format'."
  (with-current-buffer (chain--debug-buffer)
    (goto-char (point-min))
    (insert (apply #'format
                   (cons (concat (format-time-string "%T: ")
                                 (car args))
                         (cdr args))))
    (newline)
    ;; pass also to caller, enabling e.g. (warn (chain-echo "..."))
    (apply #'format args)))

(defvar chain-table (make-hash-table)
  "Table where chains are saved with metadata.")

;;;###autoload
(defun chain-define (name funs)
  "Create a chain named NAME.
FUNS should be a list of functions or lambdas, each taking at
least one argument."
  (puthash name `(nil nil 0 ,funs) chain-table))

;; Reason I didn't opt for `cl-defstruct': No more bug-proof than before.
;; Because I will not stop using `cl-symbol-macrolet', I use "nth 0", "nth 1",
;; "nth 2" in very few places already, impossible to mistake.  With that in
;; mind, replacing them with struct accessors is just gilding doorways.

(defmacro chain-running (name)
  "Get the variable \"running\" from chain identified by NAME."
  `(nth 0 (gethash ,name chain-table)))

(defmacro chain-state (name)
  "Get the variable \"state\" from chain identified by NAME.
The expression (chain-state NAME) returns the list of functions
that remain to be executed for that chain.

If, as most likely, we're called from within a function that's
called by a running chain, you can schedule a new function
invocation to be run on the next \"tick\" like this:

(push #'some-additional-function (chain-state NAME))

which can be useful for looping through a list by consuming it
one item at a time: have a function push itself back onto the
queue until the list is empty."
  `(nth 1 (gethash ,name chain-table)))

(cl-defun chain--chomp
    (name &optional polite per-stage on-abort
          &aux (chain (gethash name chain-table)))
  "Call the next function in the chain identified by NAME.
Also pass NAME unmodified as an argument to this function so it
can manipulate the running chain if necessary, primarily with
`chain-state'.

Finally, schedule another invocation of `chain--chomp'.  Optional
argument POLITE ensures waiting for at least 1 second of idle
time before invoking.

PER-STAGE and ON-ABORT same as in `chain-run'."
  (cl-symbol-macrolet ((running         (nth 0 chain))
                       (state           (nth 1 chain))
                       (last-idle-value (nth 2 chain)))
    (if (and per-stage
             (eq 'please-abort (funcall per-stage)))
        ;; Abort whole chain
        (progn
          (setf running nil)
          (setf state nil)
          (funcall on-abort))
      (let ((func (pop state)))
        (condition-case err
            (progn
              ;; In case something called this function twice and it wasn't the
              ;; timer that did it (if the timer ran the function, it won't be
              ;; among the active timers while this body is executing, so the
              ;; error isn't tripped).
              (when (member (named-timer-get name) timer-list)
                (error (chain-echo "Timer was not cancelled before `chain--chomp'")))
              (setf running t)
              (chain-echo "Running: %s" func)
              (funcall func name) ;; Real work happens here
              ;; Schedule the next step.  Note to reader: draw a flowchart...
              (when state
                (let ((idled-time (or (current-idle-time) 0)))
                  (if (or (and polite
                               (time-less-p 1.0 idled-time))
                          (and (not polite)
                               (time-less-p idled-time 1.0)
                               (time-less-p last-idle-value idled-time)))
                      ;; If user hasn't done any I/O since last chomp, go go go.
                      ;; If being impolite, go even within 1.0 second timeframe
                      ;; until there is user input within that 1.0-second
                      ;; timeframe, in which case give up and be polite.
                      (named-timer-run name 0 nil #'chain--chomp name nil per-stage on-abort)
                    ;; Otherwise give Emacs a moment to respond to user input,
                    ;; and keep waiting as long as input keeps happening.
                    (named-timer-idle-run name 1.0 nil #'chain--chomp name 'politely per-stage on-abort))
                  (setf last-idle-value idled-time))))
          ((error quit)
           (chain-echo "Chain interrupted because: %s" err)
           (push func state) ;; recover so we don't skip a function just bc it failed
           (when (eq (car err) 'error)
             (setf running nil)
             (error "Function %s failed: %s" func (cdr err))))))
      ;; The chain finished.  By setting running to nil we'll know it wasn't just
      ;; a random keyboard-quit.
      (unless state
        (setf running nil)))))

(cl-defun chain-run
    (name &key on-interrupt-discovered on-start per-stage on-abort
          &aux (chain (gethash name chain-table)))
  "Run the chain of functions identified by NAME.
It must have been previously defined with `chain-define'.

The chain shall run in pseudo-asynchronous fashion, pausing for
user input to keep Emacs feeling snappy.

If the named chain is already in progress (i.e. it was launched
via an earlier invocation of this function), do nothing and let
it continue.  Only start the chain if it is not already in
progress.  Therefore, it is safe to call this function many times
in a short timespace: it will not interrupt work nor cause
redundant computation.

All the optional keyword arguments accept a function.  These
functions' return values are ignored except that if any of these
functions (other than ON-ABORT) return the symbol 'please-abort,
the chain will be aborted and the function ON-ABORT called.

If the previous chain seems to have been interrupted and left in
an incomplete state, call ON-INTERRUPT-DISCOVERED, then resume
execution of the same chain, picking it up where it was left off.

On (re-)starting a chain, call ON-START before starting.

For each function in the chain, call PER-STAGE at the beginning."
  (declare (indent defun))
  (cl-symbol-macrolet ((running         (nth 0 chain))
                       (state           (nth 1 chain))
                       (last-idle-value (nth 2 chain))
                       (template        (nth 3 chain)))
    ;; TODO: rewrite with cond to make it easier to read
    (if running
        ;; Q: can we end up in a state where timer is inactive? A: yes, it's the
        ;; normal case for chain--chomp because it's often called by a timer, which
        ;; takes itself off the timer-list prior to calling.  However, we don't
        ;; ever call chain-run with (the package-internal) timer, so
        ;; (named-timer-get name) being in timer-list basically means a state is
        ;; active, though the opposite doesn't always mean it's not.
        (progn
          (when (not (member (named-timer-get name) timer-list))
            (error (chain-echo "No timer, but `running' still t")))
          (if state
              (chain-echo "Already running chain, letting it continue")
            ;; TODO: is it just during debugging we end up in this state? No.
            (error (chain-echo "Chain empty but `running' still t"))))
      (if (and (not running)
               state
               (not (equal state template)))
          ;; Something must have interrupted execution.  Resume.
          (if (or (not on-interrupt-discovered)
                  (and on-interrupt-discovered
                       (not (eq 'please-abort (funcall on-interrupt-discovered)))))
              ;; The on-interrupt-discovered function returned OK, or we didn't have such a function to run
              (progn
                (chain-echo "Chain had been interrupted, resuming")
                (chain--chomp name 'politely per-stage on-abort))
            (named-timer-cancel name)
            (setf running nil)
            (setf state nil)
            (funcall on-abort))
        (if (or (not on-start)
                (and on-start
                     (not (eq 'please-abort (funcall on-start)))))
            ;; The on-start function returned OK, or we didn't have such a function to run
            (progn
              (chain-echo "Launching new chain.  Unexecuted from last chain: %s" state)
              (named-timer-cancel name)
              (setf state template)
              (setf last-idle-value 1.0) ;; HACK so `chain--chomp' won't wait
              (chain--chomp name nil per-stage on-abort))
          (named-timer-cancel name)
          (setf running nil)
          (setf state nil)
          (funcall on-abort))))))

(provide 'chain)
