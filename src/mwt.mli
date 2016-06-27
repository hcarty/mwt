(** {1 Preemptive threads in Lwt sauce} *)

val detach :
  ?init:(unit -> unit) ->
  ?at_exit:(unit -> unit) ->
  ('a -> 'b) -> 'a -> 'b Lwt.t
(** [detach f x] will run [f x] in a freshly created preemptive thread.  The
    preemptive thread will end when [f x] returns. *)

module Pool : sig
  (** {2 Preemptive thread pools} *)

  type t
  (** Preemptive thread pool *)

  val make : ?init:(unit -> unit) -> ?at_exit:(unit -> unit) -> int -> t
  (** [make ?max_threads_queued ?init ?at_exit num_threads] creates a new pool
      of [num_threads] preemptive threads.

      @param init is run when each thread in the pool is created
      @param at_exit is run when each thread in the pool exits *)

  val detach : t -> ('a -> 'b) -> 'a -> 'b Lwt.t
  (** [detach pool f x] will run [f x] in one of the preemptive threads in
      [pool]. *)

  val run_in_main : (unit -> 'a Lwt.t) -> 'a
  (** [run_in_main f x] can be used to run [f x] in the program's main
      thread. *)
end
