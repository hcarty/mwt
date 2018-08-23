(** {1 Preemptive threads managed from Lwt}

    This module provides a way to call a function from Lwt and have that
    function in a separate OCaml preemptive thread. *)

(** {2 Preemptive thread pools}

    Pools of threads which may be delegated to from an Lwt application.  Each
    thread in the pool carries its own local state which is passed to any
    function running within a pool's thread. *)

(** {3 Creating a thread pool} *)

(** Preemptive thread pool carrying some local state type *)
type 'state t

val make :
  init:(unit -> 'state) -> at_exit:('state -> unit) -> int -> 'state t Lwt.t
(** [make ~init ~at_exit num_threads] creates a new pool of [num_threads]
    preemptive threads.  If no special per-thread state is required you can
    pass {!noop} to [init] and [at_exit].  The returned promise will resolve
    once all [num_threads] calls to [init] have completed.  If any instance of
    [init] raises an exception then the resulting promise will resolve to the
    same exception.

    @param init is run from within each newly created thread in the pool.  Its
    return value defines the initial state of the newly initialized thread.
    @param at_exit is run within each thread in the pool immediately before
    that thread exits.  Its argument is the state of the exiting thread.

    @raise Invalid_argument if [num_threads < 1]. *)

val noop : unit -> unit
(** [noop] may be passed to the [init] and [at_exit] parameters of {!make} when
    no special per-thread initialization or cleanup is required.  [noop] is
    [fun () -> ()]. *)

(** {3 Using a thread pool} *)

val run : 'state t -> ('state -> 'a) -> 'a Lwt.t
(** [run pool f] will run [f state] in one of the preemptive threads in
    [pool], where [state] carries the state of the thread [f] runs under.  If
    there is a thread available in [pool] then the call will block until [f]
    completes.  If no thread is available from [pool] then the call to [f] will
    be queued until a thread in [pool] is available.

    [f] may use {!run_in_main} to run code in a program's Lwt context. *)

val close : _ t -> unit Lwt.t
(** [close pool] immediately marks [pool] as closed, quits all idle threads in
    the pool and blocks until all in-use threads have terminated.  Any further
    uses of [pool] will raise [Invalid_argument]. *)

val close_async : _ t -> unit
(** [close_async pool] marks [pool] as closed and sends a "quit" signal to all
    idle threads.  Any threads currently in use will quit once they are done
    with their current task.  This function does not block. *)

(** {2 Calling back into Lwt from a preemptive thread} *)

val run_in_main : (unit -> 'a Lwt.t) -> 'a
(** [run_in_main f] can be used from within a preemptive thread to run [f ()]
    in the program's main Lwt context.  It can be seen as a dual to {!run}
    and {!run_thread}. *)
