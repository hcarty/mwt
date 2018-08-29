# Mwt - Preemptive threads and thread pools for Lwt

[![Build Status](https://travis-ci.com/hcarty/mwt.svg?branch=master)](https://travis-ci.com/hcarty/mwt)

`Mwt` allows a Lwt promise to hand off tasks to OCaml's preemptive threads.

`Mwt` is similar to `Lwt_preemptive`, but with user-managed pools of stateful
threads.  Each thread in a pool has a local state which persists for the life
of the thread.
