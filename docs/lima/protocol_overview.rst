Overview of the economic protocol
=================================

Tezos overview
~~~~~~~~~~~~~~

Tezos is a distributed system in which nodes agree upon a chain of blocks of
operations. Tezos is also an account-based crypto-ledger, where an account is
associated to a public-private key pair, and has a balance, that is, a number of
tokens. Tezos is a :doc:`proof-of-stake<proof_of_stake>` system in which any
account that has a minimal stake amount has the right to produce blocks, in
proportion to their balance.

A Tezos node has mainly three roles: it validates blocks and operations, it
broadcasts them to (and retrieves them from) other nodes, and it maintains a
main chain and its associated state (i.e. the ledger), which includes accounts
and their balances, among other things. Note that, as blocks only specify a
predecessor block, exchanged blocks do not necessarily form a chain, but rather
a tree. Nodes communicate over :doc:`a gossip network<../shell/p2p>`.

A Tezos node acts as a server, which responds to queries and requests from
clients. Such queries and requests are implemented via :doc:`RPC
calls<../developer/rpc>`. A client can query the chain’s state and can inject
blocks and operations into a node. One particular client is the :ref:`baker daemon <baker_run>`,
which is associated to an account. In particular the baker has access to the
account’s private key and thus can sign blocks and operations.

The main reason for using such a client-server architecture is safety: to insulate
the component that has access to the client keys, i.e. the baker, from the
component which is exposed to the internet, i.e. the node. Indeed, the node and
the baker can sit on different computers and the baker does not need to be
exposed to the internet. So nodes manage communication and shield bakers from
network attacks, and bakers hold secrets and bake blocks into the blockchain.

Another advantage of this architecture is that bakers can more easily have
different implementations, and this is important, for instance because different bakers may want
to implement different transaction selection strategies.

Tezos is a self-amending blockchain, in that a large part of Tezos can be
changed through a so-called amendement procedure. To this end, as mentioned in
:doc:`the big picture<../shell/the_big_picture>`, a Tezos node consists of two
components:

- the shell, which comprises the network and storage layer, and embeds
- the economic protocol component, which is the part that can be changed through amendment.

The role of the protocol
~~~~~~~~~~~~~~~~~~~~~~~~

At a very high level, a protocol must:

- implement protocol-specific types, such as the type of operations or protocol-specific block header data (in addition to the shell generic header),
- define under which conditions a block is a valid extension of the current blockchain, and define an ordering on blocks to arbitrate between concurrent extensions.

Validity conditions are implemented in the ``apply`` function which is called
whenever the node processes a block. The ``apply`` function takes as arguments a
*context* and a block. The context represents the *protocol state* and is
therefore protocol specific. The context may contain, for instance, a list of
accounts and their balances. More generally, the context must provide enough
information to determine the validity of a block. Given a context and a block,
the ``apply`` function returns the updated context if the block is valid and has
a higher :ref:`fitness<fitness_lima>`. The fitness determines a total ordering between blocks.

.. _shell_proto_interact_lima:

Shell-protocol interaction
~~~~~~~~~~~~~~~~~~~~~~~~~~

:doc:`Recall<../shell/the_big_picture>` that the economic protocol and the shell interact in order to ensure that the blocks being appended to the blockchain are valid. There are mainly two rules that the shell uses when receiving a new block:

- The shell does not accept a branch whose fork point is in a cycle more than ``PRESERVED_CYCLES`` in the past. More precisely, if ``n`` is the current cycle, :ref:`the last allowed fork point<lafl>` is the first level of cycle ``n-PRESERVED_CYCLES``. The parameter ``PRESERVED_CYCLES`` therefore plays a central role in Tezos: any block before the last allowed fork level is immutable.
- The shell changes the head of the chain to this new block only if the block is :doc:`valid<../shell/validation>` and has a higher fitness than the current head; a block is valid if the operations it includes are valid.

The support provided by the protocol for validating blocks can be modulated by different :package-api:`validation modes <tezos-protocol-alpha/Tezos_protocol_alpha/Protocol/index.html#type-validation_mode>`.
They allow using this same support for quite different use cases, as follows:

- being able to validate a block, typically used in the :doc:`validator <../shell/validation>`;
- being able to pre-apply a block, typically used in the :doc:`validator <../shell/validation>` to precheck a block, avoiding to further consider invalid blocks;
- being able to construct a block, typically used by the baker to bake a block;
- being able to partially construct a block, typically used by the :doc:`prevalidator <../shell/prevalidation>` to determine valid operations in the mempool.

Blocks
~~~~~~

A block consists of a header and operations. A block's header is
composed of two parts: :ref:`the protocol-agnostic part<shell_header>`
and :ref:`the protocol-specific part<shell_proto_revisit_lima>`.
This separation enables the shell to interact with different
protocols.

.. _validation_passes_lima:

Operations & Validation Passes
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The different kinds of operations are grouped in classes, such that operations belonging to different classes may be validated independently, and/or with different priorities.
Each class has an associated index, called a :ref:`validation pass<shell_header>`.
There are four classes of operations: :doc:`consensus <consensus>` operations, :doc:`voting <voting>` operations, anonymous operations, manager operations.

Consensus operations are endorsements, while `voting <voting>` operations are ballot and proposal.

Anonymous operations are operations which are not signed. There are three anonymous operations: seed nonce revelation, double baking evidence, and double endorsing evidence. The evidence for double baking and double endorsing is included in a block by the so-called accuser (see :ref:`slashing<slashing_lima>`).

Manager operations are activation, origination (see :doc:`smart contracts<michelson>`), transaction, reveal, and delegation (see :doc:`proof of stake <proof_of_stake>`). Manager operations are the only fee-paying operations.

Recall that users have associated :ref:`accounts <Account>` which they activate before being able to participate. By means of the operation :ref:`origination<Origination>`, accounts can be further associated with smart contracts in which they are called :ref:`originated accounts<originated account>`. :ref:`Transactions<transaction>` are used to either transfer tez between two accounts or run the code of a smart contract. Transactions are signed by an account's private key. Before making a transaction, a user must reveal her public key so that other users (not being aware of this public key) can effectively check the signature of the transaction.

Manager operations can be grouped into batches forming a so-called group operation. A group operation satisfies:

- atomicity: either all the operations in the batch succeed or none is applied
- efficiency: the whole batch is signed only once (by the same implicit account), thus it is much more efficient to check, and it requires much less gas
- usability: the batch only increments the counter of the signer account by one; for this reason it is easier for tools to provide sending several operations per block using operation batches than tracking counter changes.

The list of operations can be obtained with :ref:`this rpc <GET_..--block_id--operations>`.

.. _protocol_constants_lima:

Protocol constants
~~~~~~~~~~~~~~~~~~

Protocols are tuned by several *protocol constants*, such as the size of a nonce, or the number of blocks per cycle.
One can distinguish two kinds of protocol constants:

- *fixed* protocol constants, such as the size of a nonce, are values wired in the code of a protocol, and can only be changed by protocol amendment (that is, by adopting a new protocol)
- *parametric* protocol constants, such as the number of blocks per cycle, are values maintained in a read-only data structure that can be instantiated differently, for the same protocol, from one network to another (for instance, test networks move faster).

The *list* of protocol constants can be found in the OCaml APIs:

- fixed protocol constants are defined in the module :package-api:`Constants_repr <tezos-protocol-alpha/Tezos_raw_protocol_alpha/Constants_repr/index.html>`
- parametric constants are defined in the module :package-api:`Constants_parametric_repr <tezos-protocol-alpha/Tezos_raw_protocol_alpha/Constants_parametric_repr/index.html>`

The *values* of protocol constants in any given protocol can be found using specific RPC calls:

- one RPC for :ref:`all constants <GET_..--block_id--context--constants>`, as shown in :ref:`this example <get_protocol_constants>`
- one RPC for :ref:`the parametric constants <GET_..--block_id--context--constants--parametric>`.

Further documentation of various protocol constants can be found in the subsystems where they conceptually belong.
See, for example:

- :ref:`proof-of-stake parameters <ps_constants_lima>`.
- :ref:`consensus-related parameters <cs_constants_lima>`
- :ref:`randomness generation parameters <rg_constants_lima>`.

See also
~~~~~~~~

An in-depth description of the inners of a protocol can be found in the blog
post `How to write a Tezos protocol
<https://research-development.nomadic-labs.com/how-to-write-a-tezos-protocol.html>`_.
