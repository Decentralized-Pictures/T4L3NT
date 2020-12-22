Synchronisation heuristic
=========================

When a new node joins the network, it must **bootstrap**: fetch and
validate the chain before starting to bake or endorse new blocks. A
bootstrapping node cannot bake or endorse new blocks, so for
efficiency it should not bother to track a **mempool**: a pool of
active operations.

Knowing whether a node is bootstrapped is challenging because a node
cannot trust (in general) its neighbours. We tackle this problem using a
**synchronisation heuristic**.

Synchronisation heuristic status
--------------------------------

A synchronisation heuristic is used to determine whether the node is
synchronised with respect to its peers.

The current synchronisation heuristic uses a **synchronisation
status** as follows:

- ``Unsynced``: Not synchronised

- ``Synced``: Synchronised and the chain is not stuck

- ``Stuck``: Synchronised and the chain is stuck

Bootstrapped
------------

We consider a node bootstrapped if the heuristic's status has been
``Synced`` or ``Stuck`` at least once.

Once the node is bootstrapped, the synchronisation status is still
updated and is accessible via the RPC
``/chains/<chain>/is_bootstrapped``. This RPC returns a pair where the
first component indicates if the node is bootstrapped and the second
component is the current status.


Basic description of the heuristic
----------------------------------

The synchronisation heuristic relies on a notion of **candidate**: a
pair of a block's timestamp and a peer. The block from which the
timestamp is taken must have been validated locally and it must be the
most-recent such block advertised by the peer.

The heuristic is parameterised by two values:

- A ``threshold``: The number of candidates kept by the heuristic

- A ``latency``: A delay in seconds to control possible forks and the
  latency of the network (see :ref:`Acceptable values for
  parameters<acceptable_values>`)

The heuristic status is ``Synced`` if ``threshold`` candidates
timestamp are aged more than ``latency`` seconds from now. The
heuristic status is ``Stuck`` if ``threshold`` candidates have the
same timestamp.

.. _acceptable_values:

Acceptable values for parameters
--------------------------------

The heuristic accepts any value for the ``threshold``, but values
of ``1`` or less are mainly used for testing and debugging:

-  If ``threshold`` is negative, then the status is always ``Unsynced``

-  If ``threshold`` is ``0``, then the status is always ``Synced``

- If ``threshold`` is ``1``, then the status cannot be ``Stuck``

Other values are acceptable for ``threshold``, but a small
``threshold`` (between ``2`` and ``10``; the default being ``4``) is
probably best: performances and accuracy may degrade for values much
higher than ``10``.

The default value for ``latency`` is ``150`` seconds. Whatever you
change it to, it should be at least long enough to include a few
blocks' worth of the protocol's baking rate plus some network latency,
but not so long that the node considers itself bootstrapped even
though it is many blocks away from the chain's head.

A good value for ``latency`` is ``2`` to ``5`` times the time between
blocks, plus a small delta for network delays. At time of writing,
because of the baking priority system (see :ref:`Proof of stake in
Tezos<proof-of-stake>`) the time between two consecutive blocks is
close to ``60`` seconds when the chain is healthy.

A shorter ``latency`` might give false negatives: delays from a few
neighbours might result in the node considering itself not
synchronised yet, whilst a longer ``latency`` might give false
positives: the node considers itself synchronised whilst it still has
several blocks to catch-up on.

Formal description of the heuristic
-----------------------------------

In the normal case of the synchronisation heuristic, when the
``threshold`` parameter is greater than ``1``, the status is computed
as follows:

- The status is ``Synced`` if there are more than ``threshold``
  candidates that are more recent than ``latency``.

- The status is ``Stuck`` if the ``threshold`` most recent candidates
  have the same timestamp that is older than ``latency``.

- The status is ``Unsynced`` otherwise.


If the heuristic fails
----------------------

The heuristic may fail and declare a node not synchronised, thus not
bootstrapped, when actually it should be.  The administrator of the
node can use the RPC ``patch /chains/main {"bootstrapped": true}`` to
force the node bootstrapped state, but this should be used carefully.
If you see an issue with the current heuristic, please `report it
<https://gitlab.com/tezos/tezos/-/issues>`.
