(* Mwt, originally derived from the Lwt project's lwt_preemptive.ml *)
(* Detach a single operation into a one-off preemptive thread *)
let detach f =
  let result = ref (Error (Failure "Mwt.detach")) in
  (* Setup communication between our new thread and Lwt *)
  let waiter, wakener = Lwt.wait () in
  let id =
    Lwt_unix.make_notification ~once:true (fun () ->
        Lwt.wakeup_result wakener !result )
  in
  (* Create a new thread *)
  let thread =
    Thread.create
      (fun () ->
        (* We need to watch for exceptions from the initialization function and
           the actual task we want to run in our new thread *)
        let res = match f () with v -> Ok v | exception exn -> Error exn in
        (* Store our result and let Lwt know we're done here *)
        result := res ;
        Lwt_unix.send_notification id )
      ()
  in
  (* Keep a reference to the preemptive around for the lifetime of waiter *)
  Lwt.finalize
    (fun () -> waiter)
    (fun () -> Thread.join thread ; Lwt.return_unit)

module Pool = struct
  [@@@ocaml.warning "-3"]

  module Lwt_sequence = Lwt_sequence

  [@@@ocaml.warning "+3"]

  let noop () = ()

  type 'state worker =
    { (* Channel used to communicate notification id and tasks to the worker
         thread. *)
      task_channel: [`Task of int * ('state -> unit) | `Quit] Event.channel
    ; (* The worker thread. *)
      mutable thread: Thread.t
    ; (* The worker's parent thread pool *)
      pool: 'state t
    ; (* Wake this up when the worker quits *)
      quit: unit Lwt.u
    ; (* This will resolve once the worker quits *)
      complete: unit Lwt.t }

  and 'state t =
    { (* Has the pool been closed? *)
      mutable closed: bool
    ; (* Number of preemptive threads in the pool *)
      num_threads: int
    ; (* Initialization function for a new thread *)
      init: unit -> 'state
    ; (* Function to call when a thread is disposed of *)
      at_exit: 'state -> unit
    ; (* Queue of worker threads *)
      workers: 'state worker Queue.t
    ; (* Queue of clients waiting for a worker to be available *)
      waiters: 'state worker Lwt.u Lwt_sequence.t
    ; (* All workers in the pool, even those in use *)
      all_workers: 'state worker Weak.t }

  (* Code executed by a worker *)
  let worker_loop worker =
    let state = worker.pool.init () in
    [%defer Lwt.wakeup worker.quit ()] ;
    [%defer worker.pool.at_exit state] ;
    while not worker.pool.closed do
      match Event.sync (Event.receive worker.task_channel) with
      | `Task (id, task) ->
          task state ;
          (* Tell the main thread that work is done *)
          Lwt_unix.send_notification id
      | `Quit -> ()
    done

  (* Create a new worker *)
  let make_worker pool =
    let worker =
      let complete, quit = Lwt.wait () in
      { task_channel= Event.new_channel ()
      ; thread= Thread.self ()
      ; pool
      ; quit
      ; complete }
    in
    worker.thread <- Thread.create worker_loop worker ;
    worker

  (* Add a worker to the pool *)
  let add_worker pool worker =
    match Lwt_sequence.take_opt_l pool.waiters with
    | None -> Queue.add worker pool.workers
    | Some w -> Lwt.wakeup w worker

  (* Wait for worker to be available, then return it *)
  let get_worker pool =
    if not (Queue.is_empty pool.workers) then
      Lwt.return (Queue.take pool.workers)
    else ( Lwt.add_task_r pool.waiters [@ocaml.warning "-3"] )

  let detach pool f =
    let%lwt () =
      if pool.closed then Lwt.fail_invalid_arg "Mwt.Pool.detach"
      else Lwt.return_unit
    in
    let result = ref (Error (Failure "Mwt.Pool.detach")) in
    (* The task for the worker thread: *)
    let task state =
      try result := Ok (f state) with exn -> result := Error exn
    in
    let%lwt worker = get_worker pool in
    let waiter, wakener = Lwt.wait () in
    let id =
      Lwt_unix.make_notification ~once:true (fun () ->
          Lwt.wakeup_result wakener !result )
    in
    Lwt.finalize
      (fun () ->
        (* Send the id and the task to the worker: *)
        Event.sync (Event.send worker.task_channel (`Task (id, task))) ;
        waiter )
      (fun () -> add_worker pool worker ; Lwt.return_unit)

  let close_async pool =
    (* Close all the available worker threads in the pool *)
    pool.closed <- true ;
    Queue.iter
      (fun worker -> Event.sync (Event.send worker.task_channel `Quit))
      pool.workers

  let close pool =
    close_async pool ;
    (* Wait for all the workers to signal that they are done *)
    Array.init (Weak.length pool.all_workers) (fun i ->
        Weak.get pool.all_workers i )
    |> Array.fold_left
         (fun l worker ->
           match worker with None -> l | Some w -> w.complete :: l )
         []
    |> Lwt.join

  let make ~init ~at_exit num_threads =
    if num_threads < 1 then
      invalid_arg
        (Format.asprintf "Mwt.Pool.make: number of threads is %d, must be >= 1"
           num_threads) ;
    let pool =
      { num_threads
      ; init
      ; at_exit
      ; workers= Queue.create ()
      ; waiters= Lwt_sequence.create ()
      ; closed= false
      ; all_workers= Weak.create num_threads }
    in
    for _ = 1 to num_threads do Queue.add (make_worker pool) pool.workers done ;
    let i = ref 0 in
    Queue.iter
      (fun worker ->
        Weak.set pool.all_workers !i (Some worker) ;
        incr i )
      pool.workers ;
    pool
end

(* Calling back into the main thread *)

type 'a result = Value of 'a | Error of exn

(* Queue of [unit -> unit Lwt.t] functions. *)
let jobs = Queue.create ()

(* Mutex to protect access to [jobs]. *)
let jobs_mutex = Mutex.create ()

let job_notification =
  Lwt_unix.make_notification (fun () ->
      (* Take the first job. The queue is never empty at this point. *)
      Mutex.lock jobs_mutex ;
      let thunk = Queue.take jobs in
      Mutex.unlock jobs_mutex ;
      ignore (thunk ()) )

let run_in_main f =
  let channel = Event.new_channel () in
  (* Create the job. *)
  let job () =
    (* Execute [f] and wait for its result. *)
    let%lwt result =
      match%lwt f () with
      | ret -> Lwt.return (Value ret)
      | exception exn -> Lwt.return (Error exn)
    in
    (* Send the result. *)
    Event.sync (Event.send channel result) ;
    Lwt.return_unit
  in
  (* Add the job to the queue. *)
  Mutex.lock jobs_mutex ;
  Queue.add job jobs ;
  Mutex.unlock jobs_mutex ;
  (* Notify the main thread. *)
  Lwt_unix.send_notification job_notification ;
  (* Wait for the result. *)
  match Event.sync (Event.receive channel) with
  | Value ret -> ret
  | Error exn -> raise exn
