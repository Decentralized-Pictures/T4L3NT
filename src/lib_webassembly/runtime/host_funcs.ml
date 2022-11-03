type available_memories =
  | No_memories_during_init
  | Available_memories of Instance.memory_inst Instance.Vector.t

type reveal_destination = {base : int32; max_bytes : int32}

type reveal_func =
  available_memories ->
  Values.value list ->
  (Reveal.reveal * reveal_destination) Lwt.t

type host_func =
  | Host_func of
      (Input_buffer.t ->
      Output_buffer.t ->
      Durable_storage.t ->
      available_memories ->
      Values.value list ->
      (Durable_storage.t * Values.value list) Lwt.t)
  | Reveal_func of reveal_func

module Registry = Map.Make (String)

type registry = host_func Registry.t ref

let empty () = ref Registry.empty

let register ~global_name implem registry =
  registry := Registry.add global_name implem !registry

let lookup ~global_name registry = Registry.find global_name !registry
