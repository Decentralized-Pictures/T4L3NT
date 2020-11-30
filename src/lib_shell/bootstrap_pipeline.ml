(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs. <contact@nomadic-labs.com>               *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

open Validation_errors

(** Workflow of the bootstrap pipeline.

            +-------+
            |Locator|
            +---+---+
                |
                |
      +---------v---------+                 +----------------------+
      |      promise      <-----------------+                      |
      |  fetching headers |                 |    distributed_db    |
      |                   +----------------->                      |
      +---------+---------+                 +----------------------+
                |
                |
            +---v---+
            | pipe  |
            +---+---+
                |
                |
      +---------v---------+                 +----------------------+
      |      promise      <-----------------+                      |
      |fetching operations|                 |    distributed_db    |
      |                   +----------------->                      |
      +---------+---------+                 +----------------------+
                |
                |
            +---v---+
            | pipe  |
            +---+---+
                |
                |
      +---------v---------+                 +----------------------+
      |      promsie      <-----------------+       block          |
      | validating blocks |                 |     validator        |
      |                   +----------------->                      |
      +-------------------+                 +----------------------+
*)

(** Overview:

   The [bootstrap_pipeline] is a promise which is fulfilled when all
   block hashes of a locator has been valided. It is canceled if one
   of the three premises above fails.

   The promise "fetching headers" fetches headers step by step (a
   locator being a list of steps). [steps] are processed bottom to
   top. A [step] is a subchain delimited by two block hashes. A
   subchain being a list of block [[b1;...;bn]] such that [bi.pred] =
   hash([bj]) where i = j + 1. Headers are fetched from the
   [distributed_db] top to bottom but are enqueued in the [pipe]
   bottom to top.  The promise is fulfilled if every hashes contain in
   the locator steps were successfuly enqueued in the [pipe]. The
   promise is canceled if an error from the [distrubted_db] is raised,
   or if the [locator] was invalid.

   The promise "fetching operations" dequeue block headers and for
   each block header fetches the operations contained in the
   block. Once all the operations are fetched, it enqueues the headers
   and the operations in a [pipe] used by the promise validating
   blocks. This promise is fulfilled when it fetches all the
   operations for all the blocks that were in the input [pipe]. It is
   canceled if the [distributed_db] raised an error.

   The promise "validating blocks" dequeue full blocks and give them
   to the [Block_validator]. The promise is fulfilled is all blocks
   were validated successfuly. It is canceled otherwise. *)

(** An event is trigerred when the node is fetching large steps of a
   [Block_locator] from the network. A large step is defined by
   [big_step_size]. In that case an event is made every
   [big_step_size_announced]. *)
let (big_step_size, big_step_size_announce) = (2000, 1000)

(** The promises which fetches headers and operations communicate
   through a [Lwt_pipe]. This pipe stores headers by batch. The size
   of the batch is defined by [header_batch_size]. *)
let header_batch_size = 20

(** Size of the [Lwt_pipe] containing the fetched headers. If this
   size is reached, the promise which fetches headers holds and wait
   that the promise which fetches operations to dequeue some
   headers. This means that the maximum number of headers the queue
   can contain is [fetched_headers_queue_size] *
   [batch_header_size]. *)
let fetched_headers_queue_size = 1024

(** Size of the queue containing a full blocks (block + operations)
   before they are processed by the [Block_validator]. *)
let fetched_blocks_queue_size = 128

type t = {
  canceler : Lwt_canceler.t;
  block_header_timeout : Time.System.Span.t;
  block_operations_timeout : Time.System.Span.t;
  mutable headers_fetch_worker : unit Lwt.t;
  mutable operations_fetch_worker : unit Lwt.t;
  mutable validation_worker : unit Lwt.t;
  peer_id : P2p_peer.Id.t;
  chain_db : Distributed_db.chain_db;
  locator : Block_locator.t;
  block_validator : Block_validator.t;
  notify_new_block : State.Block.t -> unit;
  fetched_headers : (Block_hash.t * Block_header.t) list Lwt_pipe.t;
  fetched_blocks :
    (Block_hash.t * Block_header.t * Operation.t list list tzresult Lwt.t)
    Lwt_pipe.t;
  (* HACK, a worker should be able
   to return the 'error'. *)
  mutable errors : Error_monad.error list;
}

(* FIXME: this function may be called many times by different
   bootstrap pipelines on the same hash (and therefore same
   header). This can be fixed by having only one
   bootstrap_pipeline. *)

(** A block is NOT acceptable if one of the following holds:

    - The timestamp of the block is more than 15 seconds ahead in the
   future.

    - The block is at the same level as the checkpoint, but they are
   different.

    - The checkpoint has been reached (that is, the head of the chain
   is past the checkpoint) but the block is not yet in the chain. *)
let assert_acceptable_header pipeline hash (header : Block_header.t) =
  let chain_state = Distributed_db.chain_state pipeline.chain_db in
  let time_now = Systime_os.now () in
  fail_unless
    (Clock_drift.is_not_too_far_in_the_future header.shell.timestamp)
    (Future_block_header
       {block = hash; time = time_now; block_time = header.shell.timestamp})
  >>=? fun () ->
  State.Chain.checkpoint chain_state
  >>= fun checkpoint ->
  fail_when
    ( Int32.equal header.shell.level checkpoint.shell.level
    && not (Block_header.equal checkpoint header) )
    (Checkpoint_error (hash, Some pipeline.peer_id))
  >>=? fun () ->
  Chain.head chain_state
  >>= fun head ->
  let checkpoint_reached =
    (State.Block.header head).shell.level >= checkpoint.shell.level
  in
  if checkpoint_reached then
    (* If the checkpoint is reached, every block before the checkpoint
       must be part of the chain. *)
    if header.shell.level <= checkpoint.shell.level then
      Chain.mem chain_state hash
      >>= fun in_chain ->
      fail_unless in_chain (Checkpoint_error (hash, Some pipeline.peer_id))
    else return_unit
  else return_unit

(** [fetch_step] fetches block headers given a [Block_locator.step]
   and returns them as a list. It fetches headers iteratively starting
   from the top block down to the bottom block. Blocks are returned in
   the reverse order. At each iteration, the function does the
   following:

    1. First, it does some sanity check to ensure that the locator is
   valid.

    2. Then it asks to the [Distributed_db] for the block header
   associated to the hash of the block.

    3. It checks whether the received header is acceptable.

    4. It loops on the predecessor of the current block. *)
let fetch_step pipeline (step : Block_locator.step) =
  let rec fetch_loop acc hash cpt =
    Lwt_unix.yield ()
    >>= fun () ->
    ( if
      step.step > big_step_size && 0 <> cpt
      && cpt mod big_step_size_announce = 0
    then
      Bootstrap_pipeline_event.(emit still_fetching_large_step_from_peer)
        (pipeline.peer_id, cpt, step.step)
    else Lwt.return_unit )
    >>= fun () ->
    if cpt > step.step then
      Bootstrap_pipeline_event.(emit step_too_long) pipeline.peer_id
      >>= fun () -> fail (Invalid_locator (pipeline.peer_id, pipeline.locator))
    else if Block_hash.equal hash step.predecessor then
      if step.strict_step && cpt <> step.step then
        Bootstrap_pipeline_event.(emit step_too_short) pipeline.peer_id
        >>= fun () ->
        fail (Invalid_locator (pipeline.peer_id, pipeline.locator))
      else return acc
    else
      let chain_state = Distributed_db.chain_state pipeline.chain_db in
      Chain.mem chain_state hash
      >>= fun in_chain ->
      if in_chain then return acc
      else
        protect ~canceler:pipeline.canceler (fun () ->
            Distributed_db.Block_header.fetch
              ~timeout:pipeline.block_header_timeout
              pipeline.chain_db
              ~peer:pipeline.peer_id
              hash
              ())
        >>=? fun header ->
        assert_acceptable_header pipeline hash header
        >>=? fun () ->
        Bootstrap_pipeline_event.(emit fetching_block_header_from_peer)
          (hash, pipeline.peer_id, cpt, step.step)
        >>= fun () ->
        fetch_loop ((hash, header) :: acc) header.shell.predecessor (cpt + 1)
  in
  fetch_loop [] step.block 0

(** [headers_fetch_work_loop] is a promise which fetches headers
   locator step by locator step and store them in a queue. Each
   locator step is processed bottom to top by the [fetch_step]
   function. This promise is fulfilled if it fetches all the locators
   and store them successfuly in the queue. It is canceled the first
   time it was unable to fetch a header or if the [locator] was
   invalid.

   A step may be truncated in [rolling] or in [full] mode if the
   blocks are below the [savepoint].*)
let headers_fetch_worker_loop pipeline =
  (let sender_id = Distributed_db.my_peer_id pipeline.chain_db in
   (* sender and receiver are inverted here because they are from the
      point of view of the node sending the locator *)
   let seed =
     {Block_locator.sender_id = pipeline.peer_id; receiver_id = sender_id}
   in
   let chain_state = Distributed_db.chain_state pipeline.chain_db in
   let state = State.Chain.global_state chain_state in
   State.history_mode state
   >>= fun history_mode ->
   ( match history_mode with
   | History_mode.Archive ->
       Lwt.return_none
   | Full | Rolling ->
       let chain_state = Distributed_db.chain_state pipeline.chain_db in
       State.Chain.save_point chain_state >>= Lwt.return_some )
   >>= fun save_point ->
   (* In Full and Rolling mode, we do not want to receive blocks that
      are past our savepoint's level, otherwise we would start
      validating them again.  *)
   let steps =
     match save_point with
     | None ->
         Block_locator.to_steps seed pipeline.locator
     | Some (save_point_level, save_point) ->
         let (head, _) =
           (pipeline.locator : Block_locator.t :> Block_header.t * _)
         in
         let head_level = head.shell.level in
         let truncate_limit = Int32.(sub head_level save_point_level) in
         Block_locator.to_steps_truncate
           ~limit:(Int32.to_int truncate_limit)
           ~save_point
           seed
           pipeline.locator
   in
   let locator_length = Block_locator.estimated_length seed pipeline.locator in
   let number_of_steps = List.length steps in
   Bootstrap_pipeline_event.(emit fetching_locator)
     (locator_length, pipeline.peer_id, number_of_steps)
   >>= fun () ->
   match steps with
   | [] ->
       fail (Too_short_locator (sender_id, pipeline.locator))
   | {Block_locator.predecessor; _} :: _ ->
       State.Block.known chain_state predecessor
       >>= fun predecessor_known ->
       (* Check that the locator is anchored in a block locally
          known. *)
       fail_unless
         predecessor_known
         (Too_short_locator (sender_id, pipeline.locator))
       >>=? fun () ->
       (* We add the headers by batch to the fetched_headers queue.
          If the queue is full, the [Lwt_pipe.push] promise is pending
          until some headers are popped from the queue. *)
       let rec process_headers headers =
         let (batch, remaining_headers) =
           List.split_n header_batch_size headers
         in
         protect ~canceler:pipeline.canceler (fun () ->
             Lwt_pipe.push pipeline.fetched_headers batch
             >>= fun () -> return_unit)
         >>=? fun () ->
         match remaining_headers with
         | [] ->
             return_unit
         | _ ->
             process_headers remaining_headers
       in
       let rec loop counter steps =
         match steps with
         | [] ->
             return_unit
         | current :: rest ->
             let open Block_locator in
             Bootstrap_pipeline_event.(emit fetching_step_from_peer)
               ( counter,
                 number_of_steps,
                 current.step,
                 current.block,
                 current.predecessor,
                 pipeline.peer_id )
             >>= fun () ->
             fetch_step pipeline current
             >>=? process_headers
             >>=? fun () -> loop (succ counter) rest
       in
       loop 1 steps)
  >>= function
  | Ok () ->
      Bootstrap_pipeline_event.(emit fetching_all_steps_from_peer)
        pipeline.peer_id
      >>= fun () ->
      Lwt_pipe.close pipeline.fetched_headers ;
      Lwt.return_unit
  | Error (Exn Lwt.Canceled :: _)
  | Error (Canceled :: _)
  | Error (Exn Lwt_pipe.Closed :: _) ->
      Lwt.return_unit
  | Error (Distributed_db.Block_header.Timeout bh :: _) ->
      Bootstrap_pipeline_event.(emit header_request_timeout)
        (bh, pipeline.peer_id)
      >>= fun () -> Lwt_canceler.cancel pipeline.canceler
  | Error (Future_block_header {block; block_time; time} :: _) ->
      Bootstrap_pipeline_event.(emit locator_contains_future_block)
        (block, pipeline.peer_id, time, block_time)
      >>= fun () -> Lwt_canceler.cancel pipeline.canceler
  | Error (Too_short_locator _ :: _ as err) ->
      pipeline.errors <- pipeline.errors @ err ;
      Bootstrap_pipeline_event.(emit locator_too_short) ()
      >>= fun () -> Lwt_canceler.cancel pipeline.canceler
  | Error err ->
      pipeline.errors <- pipeline.errors @ err ;
      Bootstrap_pipeline_event.(emit unexpected_error_while_fetching_headers)
        err
      >>= fun () -> Lwt_canceler.cancel pipeline.canceler

(** [operations_fetch_worker_loop] is a promise which fethches
   operations and store them with the corresponding header to a
   queue. Operations are fetched block by block bottom to top. The
   promise is fulfilled if every operation was fetched and stored
   successfuly in the queue. It is canceled if one operation could not
   be fetched. *)
let rec operations_fetch_worker_loop pipeline =
  Lwt_unix.yield ()
  >>= (fun () ->
        protect ~canceler:pipeline.canceler (fun () ->
            Lwt_pipe.pop pipeline.fetched_headers >>= return)
        >>=? fun batch ->
        map_p
          (fun (hash, header) ->
            Bootstrap_pipeline_event.(emit fetching_operations)
              (hash, pipeline.peer_id)
            >>= fun () ->
            let operations =
              map_p
                (fun i ->
                  protect ~canceler:pipeline.canceler (fun () ->
                      Distributed_db.Operations.fetch
                        ~timeout:pipeline.block_operations_timeout
                        pipeline.chain_db
                        ~peer:pipeline.peer_id
                        (hash, i)
                        header.Block_header.shell.operations_hash
                      >>= fun res -> Lwt.return res))
                (0 -- (header.shell.validation_passes - 1))
              >>=? fun operations ->
              Bootstrap_pipeline_event.(emit fetched_operations)
                (hash, pipeline.peer_id)
              >>= fun () -> return operations
            in
            return (hash, header, operations))
          batch
        >>=? fun operationss ->
        iter_s
          (fun (hash, header, operations) ->
            protect ~canceler:pipeline.canceler (fun () ->
                Lwt_pipe.push pipeline.fetched_blocks (hash, header, operations)
                >>= fun () -> return_unit))
          operationss)
  >>= function
  | Ok () ->
      operations_fetch_worker_loop pipeline
  | Error (Exn Lwt.Canceled :: _)
  | Error (Canceled :: _)
  | Error (Exn Lwt_pipe.Closed :: _) ->
      Lwt_pipe.close pipeline.fetched_blocks ;
      Lwt.return_unit
  | Error (Distributed_db.Operations.Timeout (bh, n) :: _) ->
      Bootstrap_pipeline_event.(emit request_operations_timeout)
        (bh, n, pipeline.peer_id)
      >>= fun () -> Lwt_canceler.cancel pipeline.canceler
  | Error err ->
      pipeline.errors <- pipeline.errors @ err ;
      Bootstrap_pipeline_event.(emit unexpected_error_while_fetching_headers)
        err
      >>= fun () -> Lwt_canceler.cancel pipeline.canceler

(** [validation_work_loop] is a promise which validates blocks one by
   one using the [Block_validator.validate] function. Each validated
   block calls the [notify_new_block] callback. The promise is
   fulfilled if every block from the locator was validated. It is
   canceled if the validation of one block fails. *)
let rec validation_worker_loop pipeline =
  Lwt_unix.yield ()
  >>= (fun () ->
        protect ~canceler:pipeline.canceler (fun () ->
            Lwt_pipe.pop pipeline.fetched_blocks >>= return)
        >>=? fun (hash, header, operations) ->
        Bootstrap_pipeline_event.(emit requesting_validation)
          (hash, pipeline.peer_id)
        >>= fun () ->
        operations
        >>=? fun operations ->
        protect ~canceler:pipeline.canceler (fun () ->
            Block_validator.validate
              ~canceler:pipeline.canceler
              ~notify_new_block:pipeline.notify_new_block
              pipeline.block_validator
              pipeline.chain_db
              hash
              header
              operations)
        >>=? fun _block ->
        Bootstrap_pipeline_event.(emit validated_block) (hash, pipeline.peer_id)
        >>= fun () -> return_unit)
  >>= function
  | Ok () ->
      validation_worker_loop pipeline
  | Error ((Exn Lwt.Canceled | Canceled | Exn Lwt_pipe.Closed) :: _) ->
      Lwt.return_unit
  | Error
      ( ( Block_validator_errors.Invalid_block _
        | Block_validator_errors.Unavailable_protocol _
        | Block_validator_errors.System_error _
        | Timeout )
        :: _ as err ) ->
      (* Propagate the error to the peer validator. *)
      pipeline.errors <- pipeline.errors @ err ;
      Lwt_canceler.cancel pipeline.canceler
  | Error err ->
      pipeline.errors <- pipeline.errors @ err ;
      Bootstrap_pipeline_event.(emit unexpected_error_while_fetching_headers)
        err
      >>= fun () -> Lwt_canceler.cancel pipeline.canceler

(** The creation of the bootstrap starts three promises:

    - One to fetch block headers

    - One to fetch block operations

    - One which validates operations

    It intializes two pipes so that promises can communicate each
   others (see diagram at the begining of the file). *)
let create ?(notify_new_block = fun _ -> ()) ~block_header_timeout
    ~block_operations_timeout block_validator peer_id chain_db locator =
  let canceler = Lwt_canceler.create () in
  let fetched_headers =
    Lwt_pipe.create ~size:(fetched_headers_queue_size, fun _ -> 1) ()
  in
  let fetched_blocks =
    Lwt_pipe.create ~size:(fetched_blocks_queue_size, fun _ -> 1) ()
  in
  let pipeline =
    {
      canceler;
      block_header_timeout;
      block_operations_timeout;
      headers_fetch_worker = Lwt.return_unit;
      operations_fetch_worker = Lwt.return_unit;
      validation_worker = Lwt.return_unit;
      notify_new_block;
      peer_id;
      chain_db;
      locator;
      block_validator;
      fetched_headers;
      fetched_blocks;
      errors = [];
    }
  in
  Lwt_canceler.on_cancel pipeline.canceler (fun () ->
      Lwt_pipe.close fetched_blocks ;
      Lwt_pipe.close fetched_headers ;
      (* TODO proper cleanup of resources... *)
      Lwt.return_unit) ;
  let (head, _) = (pipeline.locator : Block_locator.t :> _ * _) in
  let hash = Block_header.hash head in
  pipeline.headers_fetch_worker <-
    Lwt_utils.worker
      (Format.asprintf
         "bootstrap_pipeline-headers_fetch.%a.%a"
         P2p_peer.Id.pp_short
         peer_id
         Block_hash.pp_short
         hash)
      ~on_event:Internal_event.Lwt_worker_event.on_event
      ~run:(fun () -> headers_fetch_worker_loop pipeline)
      ~cancel:(fun () -> Lwt_canceler.cancel pipeline.canceler) ;
  pipeline.operations_fetch_worker <-
    Lwt_utils.worker
      (Format.asprintf
         "bootstrap_pipeline-operations_fetch.%a.%a"
         P2p_peer.Id.pp_short
         peer_id
         Block_hash.pp_short
         hash)
      ~on_event:Internal_event.Lwt_worker_event.on_event
      ~run:(fun () -> operations_fetch_worker_loop pipeline)
      ~cancel:(fun () -> Lwt_canceler.cancel pipeline.canceler) ;
  pipeline.validation_worker <-
    Lwt_utils.worker
      (Format.asprintf
         "bootstrap_pipeline-validation.%a.%a"
         P2p_peer.Id.pp_short
         peer_id
         Block_hash.pp_short
         hash)
      ~on_event:Internal_event.Lwt_worker_event.on_event
      ~run:(fun () -> validation_worker_loop pipeline)
      ~cancel:(fun () -> Lwt_canceler.cancel pipeline.canceler) ;
  pipeline

let wait_workers pipeline =
  pipeline.headers_fetch_worker
  >>= fun () ->
  pipeline.operations_fetch_worker >>= fun () -> pipeline.validation_worker

let wait pipeline =
  wait_workers pipeline
  >>= fun () ->
  match pipeline.errors with
  | [] ->
      return_unit
  | errors ->
      Lwt.return_error errors

let cancel pipeline =
  Lwt_canceler.cancel pipeline.canceler >>= fun () -> wait_workers pipeline

let length pipeline =
  Peer_validator_worker_state.Worker_state.
    {
      fetched_header_length = Lwt_pipe.length pipeline.fetched_headers;
      fetched_block_length = Lwt_pipe.length pipeline.fetched_blocks;
    }

let length_zero =
  Peer_validator_worker_state.Worker_state.
    {fetched_header_length = 0; fetched_block_length = 0}
