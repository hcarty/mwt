# Mwt - Preemptive threads and thread pools for Lwt

`Mwt` allows a Lwt promise to hand off a tasks to OCaml's preemptive threads.

`Mwt` is similar to `Lwt_preemptive`, but with user-managed thread pools and
one-off threads.  Each thread in a pool has a local state which persists for
the life of the thread.
