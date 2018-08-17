(* Mwt, derived from the Lwt project's lwt_preemptive.ml
 * Copyright (C) 2005 Nataliya Guts, Vincent Balat, Jérôme Vouillon
 * Laboratoire PPS - CNRS Université Paris Diderot
 *               2009 Jérémie Dimino
 *               2016 Hezekiah Carty (Mwt modifications of Lwt_preemptive)
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later version.
 * See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
*)

open Lwt.Infix

[@@@ocaml.warning "-3"]

module Lwt_sequence = Lwt_sequence

[@@@ocaml.warning "+3"]

let maybe_do o x = match o with None -> () | Some f -> f x

let detach ?init ?at_exit f =
  let result = ref (Error (Failure "Mwt.run")) in
  let waiter, wakener = Lwt.wait () in
  let id =
    Lwt_unix.make_notification ~once:true (fun () ->
        Lwt.wakeup_result wakener !result )
  in
  let thread =
    Thread.create
      (fun () ->
        let res =
          try
            maybe_do init () ;
            let v = Ok (f ()) in
            maybe_do at_exit () ; v
          with exn ->
            let v = Error exn in
            maybe_do at_exit () ; v
        in
        result := res ;
        Lwt_unix.send_notification id )
      ()
  in
  (* Keep a reference to the preemptive around for the lifetime of waiter *)
  Lwt.finalize
    (fun () -> waiter)
    (fun () -> Thread.join thread ; Lwt.return_unit)


module Pool = struct
  type worker =
    { task_channel: [`Task of int * (unit -> unit) | `Quit] Event.channel
    ; (* Channel used to communicate notification id and tasks to the
       worker thread. *)
    mutable thread: Thread.t
    ; (* The worker thread. *)
    pool: t
    (* The worker's parent thread pool *) }

  and t =
    { mutable closed: bool
    ; (* Has the pool been closed? *)
    num_threads: int
    ; (* Number of preemptive threads in the pool *)
    workers: worker Queue.t
    ; (* Queue of worker threads *)
    waiters: worker Lwt.u Lwt_sequence.t
    (* Queue of clients waiting for a
                                              worker to be available *)
    }

  (* Code executed by a worker: *)
  let worker_loop ?init ?at_exit worker =
    maybe_do init () ;
    let continue = ref true in
    while !continue do
      match Event.sync (Event.receive worker.task_channel) with
      | `Task (id, task) ->
          task () ;
          (* Tell the main thread that work is done: *)
          Lwt_unix.send_notification id
      | `Quit -> continue := false
    done ;
    maybe_do at_exit ()


  (* create a new worker: *)
  let make_worker ?init ?at_exit pool =
    let worker =
      {task_channel= Event.new_channel (); thread= Thread.self (); pool}
    in
    worker.thread <- Thread.create (worker_loop ?init ?at_exit) worker ;
    worker


  (* Add a worker to the pool *)
  let add_worker pool worker =
    match Lwt_sequence.take_opt_l pool.waiters with
    | None -> Queue.add worker pool.workers
    | Some w -> Lwt.wakeup w worker


  (* Wait for worker to be available, then return it: *)
  let get_worker pool =
    if not (Queue.is_empty pool.workers) then
      Lwt.return (Queue.take pool.workers)
    else ( Lwt.add_task_r pool.waiters [@ocaml.warning "-3"] )


  let detach pool f =
    ( if pool.closed then Lwt.fail_invalid_arg "Mwt.Pool.detach"
    else Lwt.return_unit )
    >>= fun () ->
    let result = ref (Error (Failure "Mwt.detach")) in
    (* The task for the worker thread: *)
    let task () = try result := Ok (f ()) with exn -> result := Error exn in
    get_worker pool
    >>= fun worker ->
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


  let close pool =
    Queue.iter
      (fun worker -> Event.sync (Event.send worker.task_channel `Quit))
      pool.workers ;
    pool.closed <- true


  let make ?init ?at_exit num_threads =
    let pool =
      { num_threads
      ; workers= Queue.create ()
      ; waiters= Lwt_sequence.create ()
      ; closed= false }
    in
    for _i = 1 to num_threads do
      Queue.add (make_worker ?init ?at_exit pool) pool.workers
    done ;
    pool


  (* +-----------------------------------------------------------------+
     | Running Lwt threads in the main thread                          |
     +-----------------------------------------------------------------+ *)

  type 'a result = Value of 'a | Error of exn

  (* Queue of [unit -> unit Lwt.t] functions. *)
  let jobs = Queue.create ()

  (* Mutex to protect access to [jobs]. *)
  let jobs_mutex = Mutex.create ()

  let job_notification =
    Lwt_unix.make_notification (fun () ->
        (* Take the first job. The queue is never empty at this
            point. *)
        Mutex.lock jobs_mutex ;
        let thunk = Queue.take jobs in
        Mutex.unlock jobs_mutex ;
        ignore (thunk ()) )


  let run_in_main f =
    let channel = Event.new_channel () in
    (* Create the job. *)
    let job () =
      (* Execute [f] and wait for its result. *)
      Lwt.try_bind f
        (fun ret -> Lwt.return (Value ret))
        (fun exn -> Lwt.return (Error exn))
      >>= fun result ->
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
end
