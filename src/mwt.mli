(** {1 Preemptive threads in Lwt sauce} *)

val detach :
  ?init:(unit -> unit) ->
  ?at_exit:(unit -> unit) ->
  (unit -> 'a) -> 'a Lwt.t
(** [detach f] will run [f ()] in a freshly created preemptive thread.  The
    preemptive thread will end when [f ()] returns. *)

module Pool : sig
  (** {2 Preemptive thread pools} *)

  type t
  (** Preemptive thread pool *)

  val make : ?init:(unit -> unit) -> ?at_exit:(unit -> unit) -> int -> t
  (** [make ?max_threads_queued ?init ?at_exit num_threads] creates a new pool
      of [num_threads] preemptive threads.

      @param init is run when each thread in the pool is created
      @param at_exit is run when each thread in the pool exits *)

  val detach : t -> (unit -> 'a) -> 'a Lwt.t
  (** [detach pool f ()] will run [f ()] in one of the preemptive threads in
      [pool]. *)

  val run_in_main : (unit -> 'a Lwt.t) -> 'a
  (** [run_in_main f] can be used to run [f ()] in the program's main
      thread. *)

  val close : t -> unit
  (** [close pool] will close all the threads in [pool].  Any further uses of
      [pool] will raise [Invalid_argument]. *)
end
