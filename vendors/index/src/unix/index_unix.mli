(* The MIT License

Copyright (c) 2019 Craig Ferguson <craig@tarides.com>
                   Thomas Gazagnaire <thomas@tarides.com>
                   Ioana Cristescu <ioana@tarides.com>
                   Clément Pascutto <clement@tarides.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software. *)

module Make (K : Index.Key) (V : Index.Value) :
  Index.S with type key = K.t and type value = V.t

(** These modules should not be used. They are exposed purely for testing
    purposes. *)
module Private : sig
  module IO : Index.IO
end

type stats = {
  mutable bytes_read : int;
  mutable nb_reads : int;
  mutable bytes_written : int;
  mutable nb_writes : int;
}

val reset_stats : unit -> unit

val get_stats : unit -> stats
