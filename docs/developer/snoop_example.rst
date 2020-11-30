.. _snoop_example.rst:

Usage example
=============

We present a typical benchmark workflow using ``tezos-snoop``.
We'll consider the case of the ``blake2b`` hashing function, which
is used among other things to hash blocks, operations and contexts:

.. code-block:: ocaml

   Tezos_crypto.Blake2B.hash_bytes : ?key:bytes -> bytes list -> Tezos_crypto.Blake2B.t

At the time of writing, this function is a thin wrapper which
concatenates the list of bytes and passes it to the ``blake2b``
implementation provided by `HACL *`.

Step 1: defining the benchmark
------------------------------

Benchmarks correspond to OCaml modules implementing the ``Benchmark.S`` signature.
These must then be registered via the ``Registration.register`` function.
Of course, for this registration to happen, the file containing the benchmark
and the call to ``Registration.register`` should be linked with ``tezos-snoop``.
See the :ref:`architecture of tezos-snoop <snoop_arch.rst>` for complementary details.

We'll define the benchmark module chunk by chunk and describe each part.
Benchmarks are referenced by ``name``. The ``info`` field is a brief
description of the benchmark. Finally, there's also a system of ``tags``
that allows listing benchmarks by kind.

.. code-block:: ocaml

   module Blake2b_bench : Benchmark.S = struct
     let name = "Blake2b_example"
     let info = "Illustrating tezos-benchmark by benchmarking blake2b"
     let tags = ["example"]

Typically, a benchmark will depend on a set of parameters corresponding eg to
the parameters of the samplers used to generate input data to the function
being benchmarked. This corresponds to the type ``config``. A ``default_config``
is provided, which can be overriden by specifying a well-formatted json file.
This is made possible by defining a ``config_encoding`` using the
:ref:`data-encoding<data_encoding>` library.

.. code-block:: ocaml

     type config = {max_bytes : int}
     let default_config = {max_bytes = 1 lsl 16}
     let config_encoding =
       let open Data_encoding in
       conv
         (fun {max_bytes} -> max_bytes)
         (fun max_bytes -> {max_bytes})
         (obj1 (req "max_bytes" int31))

Benchmarking involves measuring the execution time of some piece of code
and using the recorded execution time to fit a model.
As explained in the :ref:`architecture of tezos-snoop <snoop_arch.rst>`,
a model is in fact a function of two parameters: a ``workload`` and the
vector of free parameters to be fitted. The ``workload`` corresponds to
the information on the input of the function being benchmarked required
to predict its execution time. Typically, it corresponds to some notion
of "size" of the input. In order to be saved to disk, we must define
a ``workload_encoding`` as well. The ``workload`` type is abstract from the
outside of the module, however for plotting purposes it is
necessary to exhibit a vector-like structure on these workloads. The
``workload_to_vector`` function maps workloads to sparse vectors. If one is
not interested in plotting, this function can be made to always return
``Sparse_vec.String.zero``.

.. code-block:: ocaml

     type workload = {nbytes : int}
     let workload_encoding =
       let open Data_encoding in
       conv
         (fun {nbytes} -> nbytes)
         (fun nbytes -> {nbytes})
         (obj1 (req "nbytes" int31))
     let workload_to_vector {nbytes} =
       Sparse_vec.String.of_list [("nbytes", float_of_int nbytes)]

We expect the execution time of ``Blake2b.hash_bytes`` to be proportional
to the number of bytes being hashed, with possibly a small constant time overhead.
Hence, we pick an ``affine`` model. The ``affine`` model is generic, of the form
:math:`affine(n) = \theta_0 + \theta_1 \times n` with :math:`\theta_i` the free
parameters. One must explain how to convert the ``workload`` to the argument ``n``.
This is the purpose of the ``conv`` parameter.

.. code-block:: ocaml

     let models =
       [ ( "blake2b",
           Model.make
             ~conv:(fun {nbytes} -> (nbytes, ()))
             ~model:
               (Model.affine
                  ~intercept:(Free_variable.of_string "blake2b_const")
                  ~coeff:(Free_variable.of_string "blake2b_ns_p_byte")) ) ]

Finally, we can define the actual benchmark. The function to be defined
is ``create_benchmarks``, which expects to be given an ``rng_state``,
a ``bench_num`` and a ``config`` and returns a list of suspensions, each
suspension yielding a benchmark when evaluated.

One might wonder why this particular signature was been chosen, instead of
returning directly a list of benchmarks, or requiring simply a benchmark
generator to be defined.

- The current signature allows for setup code to be shared by all benchmarks
  being generated (not the case here).
- Returning a list of suspensions allows to delay the sampling process
  and the memory allocation associated to benchmark generation until
  actually needed, hence preventing memory leaks.

The auxiliary function ``blake2b_benchmark`` is in charge of
preparing a ``closure``, corresponding to a call to ``Blake2b.hash_bytes``
applied to a random ``bytes``, and the associated ``workload``, containing the
size of the random ``bytes``. We want benchmarks to be easily replayable
given a seed, hence the closure-generation function is parameterised with
an explicit ``rng_state`` of type ``Random.State.t``.

.. code-block:: ocaml

     let blake2b_benchmark rng_state config () =
       let nbytes =
         Base_samplers.sample_in_interval
           rng_state
           ~range:{min = 1; max = config.max_bytes}
       in
       let bytes = Base_samplers.uniform_bytes rng_state ~nbytes in
       let workload = {nbytes} in
       (* The closure here is the piece of code to be benchmarked. *)
       let closure () = ignore (Tezos_crypto.Blake2B.hash_bytes [bytes]) in
       Generator.Plain {workload; closure}
     let create_benchmarks ~rng_state ~bench_num config =
       List.repeat bench_num (blake2b_benchmark rng_state config)
   end (* module Blake2b_bench *)

This concludes the definition of the benchmark. Let's register it:

.. code-block:: ocaml

   let () = Registration.register (module Blake2b_bench)

For illustrative purposes, we also make the ``blake2b`` available for code generation.

.. code-block:: ocaml

   let () =
     Registration.register_for_codegen
       "blake2b_codegen"
       (Model.For_codegen (List.assoc "blake2b" Blake2b_bench.models))

Step 2: checking the timer
--------------------------

Before we perform the benchmarks, we need to ensure that the system timer
is sufficiently precise. This data is also useful to subtract the latency
of time timer for very small duration benchmarks (which is not required here).
We invoke the tool on the built-in benchmark ``TIMER_LATENCY`` and specify
that we want only one closure to benchmark (since all closures are identical
for this benchmark) but execute this closure ``100000`` times.

.. code-block:: shell

   tezos-snoop benchmark TIMER_LATENCY and save to timer.workload --bench-num 1 --nsamples 100000

The tool returns the following on standard output:

::

   Benchmarking with the following options:
   { options = { flush_cache=false;
                 stabilize_gc=false;
                 seed=self-init;
                 bench #=1;
                 nsamples/bench=100000;
                 determinizer=percentile 50;
                 cpu_affinity=none;
                 minor_heap_size=262144 words;
                 config directory=None };
      save_file = timer.workload;
      storage = Mem }
   Using default configuration for benchmark TIMER_LATENCY
   {}
   benchmarking 1/1
   stats over all benchmarks: { max_time = 25.000000 ; min_time = 25.000000 ; mean_time = 25.000000 ; sigma = 0.000000 }

This commands measures `100000` times the latency of the timer, that is
the minimum time between two timing measurements. This yields an empirical distribution
on timings. The tools takes the 50th percentile (ie the median) of the empirical distribution
and returns the result: 25ns latency. This is reasonable.
Since there's only one benchmark (with many samples), the standard deviation is by definition
zero. One could also run many benchmarks with less samples per benchmark:

.. code-block:: shell

   tezos-snoop benchmark TIMER_LATENCY and save to timer.workload --bench-num 1000 --nsamples 100

This yields on standard output:

::

   Benchmarking with the following options:
   { options = { flush_cache=false;
                 stabilize_gc=false;
                 seed=self-init;
                 bench #=1000;
                 nsamples/bench=100;
                 determinizer=percentile 50;
                 cpu_affinity=none;
                 minor_heap_size=262144 words;
                 config directory=None };
      save_file = timer.workload;
      storage = Mem }
   Using default configuration for benchmark TIMER_LATENCY
   {}
   benchmarking 1000/1000
   stats over all benchmarks: { max_time = 40.000000 ; min_time = 23.000000 ; mean_time = 24.130000 ; sigma = 0.653529 }

This is consistent with the previous results.

A reliable timer should have a latency of the order of 20 to 30 nanoseconds, with a very small standard deviation.
It can happen on some hardware or software configurations that the timer latency is of the order of
*microseconds* or worse: this makes benchmarking short-lived computations impossible.

Step 3: benchmarking
--------------------

If the results obtained in the previous section are reasonable,
we can proceed to the generation of raw timing data. We want
to invoke the ``Blake2b_example`` benchmark and save the resulting data to `./blake2b.workload`.
We want `500` distinct random inputs, and for each stack we will perform
the timing measurement `3000` times. The ``--determinizer`` option specifies
how the empirical timing distribution corresponding to the per-stack `3000` samples
will be converted to a fixed value: here we pick the 50th percentile, ie the median
(which happens to also be the default, so this last option could have been omitted).
We also use an explicit random seed in case we want to reproduce the exact same benchmarks.
If not specified, the PRNG will self-initialize using an unknown seed.

.. code-block:: shell

   tezos-snoop benchmark Blake2b_example and save to blake2b.workload --bench-num 500 --nsamples 3000 --seed 12897

Here's the output:

::

   Benchmarking with the following options:
   { options = { flush_cache=false;
                 stabilize_gc=false;
                 seed=12897;
                 bench #=500;
                 nsamples/bench=3000;
                 determinizer=percentile 50;
                 cpu_affinity=none;
                 minor_heap_size=262144 words;
                 config directory=None };
      save_file = blake2b.workload;
      storage = Mem }
   Using default configuration for benchmark Blake2b_example
   { "max_bytes": 65536 }
   benchmarking 500/500
   stats over all benchmarks: { max_time = 71957.000000 ; min_time = 284.000000 ; mean_time = 34750.532000 ; sigma = 20155.604394 }

Since the size of inputs varies a lot, the statistics over all benchmarks are less useful.

Step 3.5: (optional) removing outliers
--------------------------------------

It is possible to remove outliers from the raw benchmark data. The command is the following:

.. code-block:: shell

   tezos-snoop remove outliers from data ./blake2b.workload above 3 sigmas and save to blake2b-cleaned.workload

In this particular example, the data seems clean though:

::

   Measure.load: loaded ./blake2b.workload
   Removing outliers.
   Stats: { max_time = 71925.000000 ; min_time = 289.000000 ; mean_time = 34988.436000 ; sigma = 20766.341788 }
   Validity interval: [-27310.589365, 97287.461365].
   Removed 0 outliers out of 500 elements.

The best defence against outliers is to have clean data in the first place: use a stable environment for benchmarking.

.. _Fitting the model:

Step 4: fitting the model
-------------------------

We can now proceed to inferring the free parameters from the model using the data.
At the time of writing, the tool offloads the regression problem to the scikit-learn
(aka sklearn) Python library: install it before proceeding. Let's execute the following command:

.. code-block:: shell

   tezos-snoop infer parameters for model blake2b on data blake2b.workload using lasso --lasso-positive --dump-csv blake2b.csv --save-solution blake2b.sol --plot

::

   Initializing python... Done.
   Measure.load: loaded blake2b.workload
   Applying model to workload data 500/500
   Initializing matrices 500/500
   Importing blake2b.csv
   Exporting to blake2b.csv
   Saved solution to blake2b.sol

The command performed the following tasks:

- load the workload data from `blake2b.workload`;
- construct a linear regression problem using the chosen model: here,
  the ``Blake2b_example`` benchmark only provides the ``blake2b`` model;
- solve this problem using the specified ``lasso`` algorithm, with the
  constraint that the inferred coefficients must be positive;
- dump the result of inference to a csv file named `blake2b.csv`;
- save a structured solution (useful for code generation) to `blake2b.sol`;
- plot the result of inference.

Let's first have a look at the contents of the CSV solution `blake2b.csv`.

.. csv-table:: Inference results
   :header: "blake2b_const", "blake2b_ns_p_byte"

   129.279086813,1.09627036127

The columns correspond to the inferred values for the free
variables of the ``blake2b`` cost model. The units are respectively
ns/bytes for ``blake2b_ns_p_byte`` and ns for ``blake2b_const``.

The tool also produces a plot:

.. image:: images/inference.png

The leftmost figure plots the empirical data, i.e. the raw execution time
(in nanoseconds) as a function of the input size (here, in bytes -- other
data structures might use different notions of sizes). The rightmost figure
plots the empirical data along the predicted execution time. If the model
is good and the parameters were correctly fitted, these should match.
The central plot is useful when using complex nonlinearities to model
the execution time of some piece of code: the tool will project back the
raw data in the linear space spanned by the chosen nonlinearities and
if the model is good, one should observe that the empirical data lies
along a linear subspace. Here, the model is trivial so the central plot
is less interesting.

Step 5: generating code
-----------------------

As a final step, we demonstrate how to generate code corresponding to the
model. This is typically used to generate gas consumption functions
for Michelson instructions and not for raw functions like ``blake2b``
but the principle is similar.

.. code-block:: shell

   tezos-snoop generate code using solution blake2b.sol and model blake2b_codegen

The tool produces the following code on ``stdout``:

::

   let model_blake2b_codegen = fun size -> (129.279086813 + (1.09627036127 * size))

It is also possible to generate code implementing the cost function using
fixed-point arithmetic. This requires specifying some codegen parameters in a json
file. For instance, we can require to consider 5 bits of precision and use
rounding to nearest to convert constants, failing if we make more than 10% relative
error when casting.

.. code-block:: JSON

   { "precision": 5, "max_relative_error": 0.1, "cast_mode": "Round" }

Calling the tool:

.. code-block:: shell

   tezos-snoop generate code using solution blake2b.sol and model blake2b_codegen --fixed-point codegen_params.json

We get:

::

   let model_blake2b_codegen = fun size -> let v0 = size in (129 + ((v0 + (v0 lsr 4)) + (v0 lsr 5)))
