;; epoll

;;;; Copyright (C) 2016 Andy Wingo <wingo@pobox.com>
;;;; Copyright (C) 2022 Maxime Devos <maximedevos@telenet.be>
;;;; Copyright (C) 2022 Aleix Conchillo Flaqué <aconchillo@gmail.com>
;;;;
;;;; This library is free software; you can redistribute it and/or
;;;; modify it under the terms of the GNU Lesser General Public
;;;; License as published by the Free Software Foundation; either
;;;; version 3 of the License, or (at your option) any later version.
;;;;
;;;; This library is distributed in the hope that it will be useful,
;;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;;; Lesser General Public License for more details.
;;;;
;;;; You should have received a copy of the GNU Lesser General Public License
;;;; along with this program.  If not, see <http://www.gnu.org/licenses/>.
;;;;

(define-module (fibers events-impl)
  #:use-module ((ice-9 binary-ports) #:select (get-u8 put-u8))
  #:use-module (ice-9 atomic)
  #:use-module (ice-9 control)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-9 gnu)
  #:use-module (rnrs bytevectors)
  #:use-module (fibers config)
  #:export (events-impl-create
            events-impl-destroy
            events-impl?
            events-impl-add!
            events-impl-wake!
            events-impl-fd-finalizer
            events-impl-run

            EVENTS_IMPL_READ EVENTS_IMPL_WRITE EVENTS_IMPL_CLOSED_OR_ERROR))

(eval-when (eval load compile)
  ;; When cross-compiling, the cross-compiled 'fibers-epoll.so' cannot be loaded
  ;; by the 'guild compile' process; skip it.
  (unless (getenv "FIBERS_CROSS_COMPILING")
    (dynamic-call "init_fibers_epoll"
                  (dynamic-link (extension-library "fibers-epoll")))))

(when (defined? 'EPOLLRDHUP)
  (export EPOLLRDHUP))
(when (defined? 'EPOLLONESHOT)
  (export EPOLLONESHOT))

(define (make-wake-pipe)
  (let ((pair (pipe2 (logior O_NONBLOCK O_CLOEXEC))))
    (match pair
      ((read-pipe . write-pipe)
       (setvbuf write-pipe 'none)
       (values read-pipe write-pipe)))))

(define-record-type <epoll>
  (make-epoll fd eventsv maxevents state wake-read-pipe wake-write-pipe)
  epoll?
  (fd epoll-fd set-epoll-fd!)
  (eventsv epoll-eventsv set-epoll-eventsv!)
  (maxevents epoll-maxevents set-epoll-maxevents!)
  ;; atomic box of either 'waiting, 'not-waiting or 'dead
  (state epoll-state)
  (wake-read-pipe epoll-wake-read-pipe)
  (wake-write-pipe epoll-wake-write-pipe))

(define-syntax events-offset
  (lambda (x)
    (syntax-case x ()
      ((_ n)
       #`(* n %sizeof-struct-epoll-event)))))

(define-syntax fd-offset
  (lambda (x)
    (syntax-case x ()
      ((_ n)
       #`(+ (* n %sizeof-struct-epoll-event)
            %offsetof-struct-epoll-event-fd)))))

(define epoll-guardian (make-guardian))
(define (pump-epoll-guardian)
  (let ((epoll (epoll-guardian)))
    (when epoll
      (epoll-destroy epoll)
      (pump-epoll-guardian))))
(add-hook! after-gc-hook pump-epoll-guardian)

(define* (epoll-create #:key (close-on-exec? #t) (maxevents 8))
  (call-with-values (lambda () (make-wake-pipe))
    (lambda (read-pipe write-pipe)
      (let* ((state (make-atomic-box 'not-waiting))
             (epoll (make-epoll (primitive-epoll-create close-on-exec?)
                                #f maxevents state read-pipe write-pipe)))
        (epoll-guardian epoll)
        (epoll-add! epoll (fileno read-pipe) EPOLLIN)
        epoll))))

(define (epoll-destroy epoll)
  (atomic-box-set! (epoll-state epoll) 'dead)
  (when (epoll-fd epoll)
    (close-port (epoll-wake-read-pipe epoll))
    ;; FIXME: ignore errors flushing output
    (close-port (epoll-wake-write-pipe epoll))
    (close-fdes (epoll-fd epoll))
    (set-epoll-fd! epoll #f)))

(define (events-impl? impl)
  (epoll? impl))

(define (epoll-add! epoll fd events)
  (primitive-epoll-ctl (epoll-fd epoll) EPOLL_CTL_ADD fd events))

(define (epoll-modify! epoll fd events)
  (primitive-epoll-ctl (epoll-fd epoll) EPOLL_CTL_MOD fd events))

(define (epoll-add*! epoll fd events)
  (catch 'system-error
    (lambda () (epoll-modify! epoll fd events))
    (lambda _
      (epoll-add! epoll fd events))))

(define (epoll-remove! epoll fd)
  (primitive-epoll-ctl (epoll-fd epoll) EPOLL_CTL_DEL fd))

(define (epoll-wake! epoll)
  "Run after modifying the shared state used by a thread that might be
waiting on this epoll descriptor, to break that thread out of the
epoll wait (if appropriate)."
  (match (atomic-box-ref (epoll-state epoll))
    ;; It is always correct to wake an epoll via the pipe.  However we
    ;; can avoid it if the epoll is guaranteed to see that the
    ;; runqueue is not empty before it goes to poll next time.
    ('waiting
     (primitive-epoll-wake (fileno (epoll-wake-write-pipe epoll))))
    ('not-waiting #t)
    ;; This can happen if a fiber was waiting on a condition and
    ;; run-fibers completes before the fiber completes and afterwards
    ;; the condition is signalled.  In that case, we don't have to
    ;; resurrect the fiber or something, we can just do nothing.
    ;; (Bug report: https://github.com/wingo/fibers/issues/61)
    ('dead #t)))

(define (epoll-default-folder fd events seed)
  (acons fd events seed))

(define (ensure-epoll-eventsv epoll maxevents)
  (let ((prev (epoll-eventsv epoll)))
    (if (and prev
             (or (not maxevents)
                 (= (events-offset maxevents) (bytevector-length prev))))
        prev
        (let ((v (make-bytevector (events-offset (or maxevents 8)))))
          (set-epoll-eventsv! epoll v)
          v))))

(define* (epoll epoll #:key (expiry #f)
                (update-expiry (lambda (expiry) expiry))
                (folder epoll-default-folder) (seed '()))
  (define (expiry->timeout expiry)
    (cond
     ((not expiry) -1)
     (else
      (let ((now (get-internal-real-time)))
        (cond
         ((< expiry now) 0)
         (else (- expiry now)))))))
  (let* ((maxevents (epoll-maxevents epoll))
         (eventsv (ensure-epoll-eventsv epoll maxevents))
         (write-pipe-fd (fileno (epoll-wake-write-pipe epoll)))
         (read-pipe-fd (fileno (epoll-wake-read-pipe epoll))))
    (atomic-box-set! (epoll-state epoll) 'waiting)
    ;; Note: update-expiry call must take place after epoll-state is
    ;; set to waiting.
    (let* ((timeout (expiry->timeout (update-expiry expiry)))
           (n (primitive-epoll-wait (epoll-fd epoll)
                                    write-pipe-fd read-pipe-fd
                                    eventsv timeout)))
      (atomic-box-set! (epoll-state epoll) 'not-waiting)
      ;; If we received `maxevents' events, it means that probably there
      ;; are more active fd's in the queue that we were unable to
      ;; receive.  Expand our event buffer in that case.
      (when (= n maxevents)
        (set-epoll-maxevents! epoll (* maxevents 2)))
      (let lp ((seed seed) (i 0))
        (if (< i n)
            (let ((fd (bytevector-s32-native-ref eventsv (fd-offset i)))
                  (events (bytevector-u32-native-ref eventsv (events-offset i))))
              (lp (folder fd events seed) (1+ i)))
            seed)))))

(define EVENTS_IMPL_READ (logior EPOLLIN EPOLLRDHUP))
(define EVENTS_IMPL_WRITE EPOLLOUT)
(define EVENTS_IMPL_CLOSED_OR_ERROR (logior EPOLLHUP EPOLLERR))

(define events-impl-create epoll-create)

(define events-impl-destroy epoll-destroy)

(define (events-impl? impl)
  (epoll? impl))

(define (events-impl-add! impl fd events)
  (epoll-add*! impl fd (logior events EPOLLONESHOT)))

(define events-impl-wake! epoll-wake!)

(define (events-impl-fd-finalizer impl fd-waiters)
  (lambda (fd)
    ;; When a file port is closed, clear out the list of
    ;; waiting tasks so that when/if this FD is re-used, we
    ;; don't resume stale tasks. Note that we don't need to
    ;; remove the FD from the epoll set, as the kernel manages
    ;; that for us.
    ;;
    ;; FIXME: Is there a way to wake all tasks in a thread-safe
    ;; way?  Note that this function may be invoked from a
    ;; finalizer thread.
    (set-cdr! fd-waiters '())
    (set-car! fd-waiters #f)))

(define events-impl-run epoll)
