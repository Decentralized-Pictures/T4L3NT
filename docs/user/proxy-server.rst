Proxy server
------------

This page describes the *proxy server*, a readonly frontend to ``tezos-node``
which is designed to lower the load of full nodes. It can be run separately from
a node and will handle some RPC requests by itself. It is named after two
things:

* The :doc:`proxy mode<proxy>` of the client on which it builds upon.
* Regular HTTP proxies, as proxy servers are meant to be deployed
  in front of a node, to lower the node's load.

While the proxy server can only serve a subset of the RPCs a full node can serve
(detailed :ref:`below <what_the_proxy_server_serves>`), one can transparently
use a proxy server as a replacement for a full node, in the manner described
:ref:`below <unsupported_rpcs>`: it will use HTTP redirects to redirect clients
to the node when it cannot handle a certain request.

Launching a proxy server
~~~~~~~~~~~~~~~~~~~~~~~~

The minimal arguments to launch a proxy server are ``--endpoint``
and ``--rpc-addr``:

* ``--endpoint`` specifies the URL of the RPC server of the node
  to do requests to obtain data (RPCs of the form
  ``/chains/<chain_id>/blocks/<block_id>/context/raw/bytes``).
* ``--rpc-addr`` specifies the URL that the proxy server should serve.

Another important argument is ``--data-dir``:

* ``--data-dir`` specifies the directory of the node from
  which to obtain data. This argument can only be used when the proxy server
  has actual access to the specified data directory.
  In this case, this option will reduce the number of RPC calls to the
  node, thereby reducing its IO consumption.

The full list of arguments is detailed :ref:`below <additional_arguments>`.

.. _sandbox_example:

Example with the sandbox
~~~~~~~~~~~~~~~~~~~~~~~~

In this section, we show examples of usage of a proxy server when using
the :doc:`sandboxed node<sandbox>`. For convenience we repeat
instructions for the sandboxed mode here, but refer the reader to the
sandboxed mode page for further details. First, edit
``src/proto_alpha/parameters/sandbox-parameters.json``
to set the first value of ``time_between_blocks`` to ``15`` seconds (it's
the time between two blocks in the chain, we set it to ``15`` seconds,
so that the scenario below is easier to understand):

::

    { ...,
      "time_between_blocks": [ "15", "0" ],
      ...
    }

In a terminal, start a sandboxed node:

::

    $ ./src/bin_node/tezos-sandboxed-node.sh 1 --connections 1
      April 21 11:05:32.789 - node.config.validation: the node configuration has been successfully validated.
      Created /tmp/tezos-node.Uzq5aGAN/config.json for network: sandbox.
      ...

Leave that terminal running. In a second terminal, prepare the appropriate
environment for using a proxy server:

::

    $ eval `./src/bin_client/tezos-init-sandboxed-client.sh 1`

Then upgrade the node to protocol alpha:

::

    $ tezos-activate-alpha
    $ tezos-client bake for bootstrap1

To avoid warnings being printed in upcoming commands (optional):

::

    $ export TEZOS_CLIENT_UNSAFE_DISABLE_DISCLAIMER=y

You're now ready to use a proxy server. Open a third terminal, and
launch a proxy server as shown below. We specify debug variables
in ``TEZOS_LOG`` to have debug output showing what the proxy server
is doing (see the :doc:`proxy mode<proxy>` page for more details).

::

    $ export TEZOS_LOG="proxy_rpc_ctxt->debug; alpha.proxy_rpc->debug; proxy_server_run->debug; proxy_getter->debug; proxy_services->debug"
    $ ./tezos-proxy-server --endpoint http://127.0.0.1:18731 --rpc-addr http://127.0.0.1:18732
      protocol of proxy unspecified, using the node's protocol: ProtoALphaALphaALphaALphaALphaALphaALphaALphaDdp3zK
      Apr 21 11:09:22.092 - proxy_server_run: starting proxy RPC server on 127.0.0.1:18732

Now, start a fourth terminal, and make a client request data from the proxy server:

::

    $ export TEZOS_CLIENT_UNSAFE_DISABLE_DISCLAIMER=y
    $ ./tezos-client --endpoint http://127.0.0.1:18732 rpc get /chains/main/blocks/head/context/contracts
      [ "tz1gjaF81ZRRvdzjobyfVNsAeSC6PScjfQwN",
        "tz1ddb9NMYHZi5UzPdzTZMYQQZoMub195zgv",
        "tz1faswCTDciRzE4oJ9jn2Vm2dvjeyA9fUzU",
        "tz1KqTpEZ7Yob7QbPE4Hy4Wo8fHG8LhKxZSx",
        "tz1b7tUupMgCNw2cCLpKTkSD1NZzB5TkP2sv" ]

In the proxy server's terminal, you should see this output (tree sizes may vary):

::

    Apr 21 11:10:07.474 - alpha.proxy_rpc: chains/<main>/blocks/<head>/header
    Apr 21 11:10:07.474 - alpha.proxy_rpc: proxy cache created for chain main and block head
    Apr 21 11:10:07.476 - proxy_getter: Cache miss: (v1/constants)
    Apr 21 11:10:07.476 - proxy_getter: split_key heuristic triggers, getting v1 instead of v1/constants
    Apr 21 11:10:07.476 - alpha.proxy_rpc: /chains/<main>/blocks/<head>/context/raw/bytes/v1
    Apr 21 11:10:07.477 - alpha.proxy_rpc: received tree of size 2
    Apr 21 11:10:07.477 - proxy_getter: Cache hit: (v1/cycle_eras)
    Apr 21 11:10:07.477 - proxy_getter: Cache miss: (pending_migration_balance_updates)
    Apr 21 11:10:07.477 - alpha.proxy_rpc: /chains/<main>/blocks/<head>/context/raw/bytes/pending_migration_balance_updates
    Apr 21 11:10:07.477 - proxy_getter: Cache miss: (pending_migration_operation_results)
    Apr 21 11:10:07.477 - alpha.proxy_rpc: /chains/<main>/blocks/<head>/context/raw/bytes/pending_migration_operation_results
    Apr 21 11:10:07.478 - proxy_getter: Cache miss: (contracts/index)
    Apr 21 11:10:07.478 - alpha.proxy_rpc: /chains/<main>/blocks/<head>/context/raw/bytes/contracts/index
    Apr 21 11:10:07.479 - alpha.proxy_rpc: received tree of size 115

Lines of the form ``alpha.proxy_rpc: /chains/<main>/blocks/<head>/context/raw/bytes/...``
show requests that the proxy server does to the node to obtain data.

``15`` seconds after the previous command, the proxy server should clear
the data it obtained, because ``time_between_blocks`` was set to ``15``
seconds at the beginning of this scenario:

::

    Apr 21 11:10:22.478 - proxy_services: clearing data for chain main and block head

Now, in the fourth terminal, retrieve the contracts again, but twice in a row:

::

    $ ./tezos-client --endpoint http://127.0.0.1:18732 rpc get /chains/main/blocks/head/context/contracts
      [ "tz1gjaF81ZRRvdzjobyfVNsAeSC6PScjfQwN",
        "tz1ddb9NMYHZi5UzPdzTZMYQQZoMub195zgv",
        "tz1faswCTDciRzE4oJ9jn2Vm2dvjeyA9fUzU",
        "tz1KqTpEZ7Yob7QbPE4Hy4Wo8fHG8LhKxZSx",
        "tz1b7tUupMgCNw2cCLpKTkSD1NZzB5TkP2sv" ]
    $ ./tezos-client --endpoint http://127.0.0.1:18732 rpc get /chains/main/blocks/head/context/contracts
      # ... same output ...

In the meantime, in the proxy server's terminal, you should see:

::

    Apr 21 11:14:04.262 - alpha.proxy_rpc: chains/<main>/blocks/<head>/header
    Apr 21 11:14:04.263 - alpha.proxy_rpc: proxy cache created for chain main and block head
    Apr 21 11:14:04.266 - proxy_getter: Cache miss: (v1/constants)
    Apr 21 11:14:04.266 - proxy_getter: split_key heuristic triggers, getting v1 instead of v1/constants
    Apr 21 11:14:04.266 - alpha.proxy_rpc: /chains/<main>/blocks/<head>/context/raw/bytes/v1
    Apr 21 11:14:04.266 - alpha.proxy_rpc: received tree of size 2
    Apr 21 11:14:04.267 - proxy_getter: Cache hit: (v1/cycle_eras)
    Apr 21 11:14:04.267 - proxy_getter: Cache miss: (pending_migration_balance_updates)
    Apr 21 11:14:04.267 - alpha.proxy_rpc: /chains/<main>/blocks/<head>/context/raw/bytes/pending_migration_balance_updates
    Apr 21 11:14:04.267 - proxy_getter: Cache miss: (pending_migration_operation_results)
    Apr 21 11:14:04.267 - alpha.proxy_rpc: /chains/<main>/blocks/<head>/context/raw/bytes/pending_migration_operation_results
    Apr 21 11:14:04.267 - proxy_getter: Cache miss: (contracts/index)
    Apr 21 11:14:04.268 - alpha.proxy_rpc: /chains/<main>/blocks/<head>/context/raw/bytes/contracts/index
    Apr 21 11:14:04.269 - alpha.proxy_rpc: received tree of size 115
    Apr 21 11:14:06.511 - proxy_getter: Cache hit: (v1/constants)
    Apr 21 11:14:06.512 - proxy_getter: Cache hit: (v1/cycle_eras)
    Apr 21 11:14:06.512 - proxy_getter: Cache hit: (pending_migration_balance_updates)
    Apr 21 11:14:06.512 - proxy_getter: Cache hit: (pending_migration_operation_results)
    Apr 21 11:14:06.512 - proxy_getter: Cache hit: (contracts/index)

The last four lines show that the proxy server is answering the request
without delegating anything to the node: there is no ``alpha.proxy_rpc`` line.
The proxy server is reusing the data it obtained for ``<head>`` from
the first request, because less than ``time_between_block`` (``15`` seconds)
have passed.

Reducing RPC calls: ``--data-dir``
""""""""""""""""""""""""""""""""""

To make the proxy server read the node's data-dir instead of doing
``/chains/<main>/blocks/<head>/context/raw/bytes`` RPC calls, kill
the proxy server you have launched :ref:`above <sandbox_example>`),
and restart it as follows:

::

    $ ./tezos-proxy-server --endpoint http://127.0.0.1:18731 --rpc-addr http://127.0.0.1:18732 --data-dir /tmp/tezos-node.Uzq5aGAN
      protocol of proxy unspecified, using the node's protocol: ProtoALphaALphaALphaALphaALphaALphaALphaALphaDdp3zK
      Apr 21 11:09:22.092 - proxy_server_run: starting proxy RPC server on 127.0.0.1:18732

The value of the ``--data-dir`` argument was obtained by looking at the
output of the terminal where ``tezos-node`` was launched
(see :ref:`above <sandbox_example>`).

Now, in the fourth terminal (the client's terminal), redo the request
to retrieve contracts:

::

    $ ./tezos-client --endpoint http://127.0.0.1:18732 rpc get /chains/main/blocks/head/context/contracts
      # ... same output as above ...

Now the output in the proxy server terminal should be:

::

    Apr 21 11:22:44.359 - alpha.proxy_rpc: chains/<main>/blocks/<head>/header
    Apr 21 11:22:44.360 - alpha.proxy_rpc: proxy cache created for chain main and block head
    Apr 21 11:22:59.362 - proxy_services: clearing data for chain main and block head

There are far fewer ``alpha.proxy_rpc`` lines! That is because the proxy
server obtained its data by reading the node's data-dir, instead of performing RPC calls.

.. _additional_arguments:

Additional arguments
~~~~~~~~~~~~~~~~~~~~

We describe the entire list of arguments of the proxy server. This
documentation is also available with ``./tezos-proxy-server --help``.
Here is the list of possible arguments:

* ``-c`` and ``--config`` specify the JSON file to use an input
  for the configuration. This JSON file is an object like this:
  ``{"endpoint": "http://127.0.0.1:18731", "rpc_addr": "http://127.0.0.1:18732", "sym_block_caching_time": 60}``.
  This file can specify all command line arguments except ``-l``/``--log-requests``.
  If an argument if specified both in the configuration file and on the command line,
  the command line takes precedence.
* ``-d`` and ``--data-dir`` specify the path of the data directory of
  the node. If specified, the proxy server obtains data by reading the disk
  instead of performing the ``/chains/<chain_id>/blocks/<block_id>/context/raw/bytes``
  RPC. If possible (i.e. if the proxy server can access the node's
  disk), this option should be used, because it reduces IO consumption
  of the node.

  Note that this argument doesn't make ``--endpoint`` optional, because the
  proxy server still needs to do RPC calls to obtain block headers. Further
  work removing all RPC calls is described in issue
  `2502 <https://gitlab.com/tezos/tezos/-/issues/2502>`_.
* ``-E`` and ``--endpoint`` specify the URL of the RPC server of the node
  to do requests to obtain data (RPCs of the form
  ``/chains/<chain_id>/blocks/<block_id>/context/raw/bytes``).
* ``-l`` and ``--log-requests`` specify to print the requests that are
  delegated to the node, in a verbose manner.
* ``--rpc-addr`` specifies the URL that the proxy server should serve.
* ``--rpc-tls`` specifies that the proxy server must use TLS. It should
  be a string of the form ``crt_file,key_file`` where ``crt_file`` is the path
  to the TLS certificate to use and ``key_file`` is the path to the key
  to use.
* ``--sym-block-caching-time`` specifies
  the duration during which data for a symbolic block identifier
  (like ``head``, ``head~1``) is kept. Smaller values increase the endpoint's
  load but yield more up-to-date to clients. Higher values
  decrease the endpoint's load but make clients observe slightly deprecated
  values. If omitted, the value is defaulted to ``time_between_blocks``. As
  ``time_between_blocks`` is hence regularly requested from the node, this incurs
  a higher load of the node.

All arguments are optional as they can either be specified in the configuration
file or on the command line. However, the union of the configuration file
and the command line should specify the endpoint to use and the RPC address to serve.

.. _what_the_proxy_server_serves:

What the proxy server serves
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The proxy server itself serves protocol-specific RPCs, which are listed
`here <https://tezos.gitlab.io/alpha/rpc.html#protocol-alpha>`_ for protocol Alpha,
but not all of them: since the proxy server is a readonly frontend for the
underlying node, it only serves the readonly requests (``GET`` requests, as
well as a subset of the ``POST`` requests).

Because computations done by the proxy server are protocol dependent, the proxy server
does not support all protocols. However, it is expected that, at any
given time, the proxy server supports ``Alpha``, the current protocol
of Mainnet and the current protocol proposal on Mainnet at the time of release.
In doubt, execute ``tezos-client list proxy protocols`` to see the supported protocols.

.. _unsupported_rpcs:

Unsupported RPCs
~~~~~~~~~~~~~~~~

Requests that are not readonly can only be handled by a full node. However, it
is possible to *send* any RPC to the proxy server: if the RPC is not supported
by the proxy server, it will redirect clients to the appropriate endpoint on the
underlying node using an HTTP redirect (``301 Moved Permanently``), and the node
will then handle the request.

This can be easily demonstrated with a simple test: start a proxy server, and
make a request to it with ``curl -vL <proxy server endpoint>/<any node-only RPC>``.
(For example, ``/chains/main/blocks/head/header`` is one such RPC.) The output
from ``curl`` will show that the proxy server asks curl to follow a redirect to
the node's endpoint, which it will do because of the ``-L`` flag, and
then it is finally responded to by the node. Any RPC that can be handled by the
proxy server itself will of course not show this behaviour.

Clearly, making such requests to the proxy server does not decrease the load of
the node. (To be precise, it in fact also adds a slight delay to the HTTP
request if the redirect is not cached by the client.) However, it does allow the
use of a single endpoint for all RPC requests, which may be more convenient for
certain use-cases.

Deployment
~~~~~~~~~~

As a proxy server is a readonly frontend to a node, you can spawn multiple
proxy servers in front of a single node.

Because the proxy server is protocol-dependent, if the node it talks to
changes protocol; the proxy server will start failing for RPCs
concerning blocks of the new protocol. We hereby recommend to automatically
restart proxy servers that have a high ratio of failures.
Restarting a proxy server is always fine, they can be thrown away at any
moment.

Heuristics
~~~~~~~~~~

The proxy server has heuristics. For example there is an heuristic
to make big map queries faster, when many queries to siblings keys of a given
big map are done in burst. The list of heuristics is
visible for protocol Alpha in
`proxy.ml <https://gitlab.com/tezos/tezos/-/blob/master/src/proto_alpha/lib_client/proxy.ml>`_.
The heuristic is implemented in function ``split_key``. For example,
any request of the form ``rolls/owner/snapshot/i/j/tail`` is transformed
into a request of the form ``rolls/owner/snapshot/i/j`` to obtain data for all
possible values of ``tail`` at once.
For the moment the heuristics cannot be specified on the command line. However,
it would be possible to do so. Please contact us for requesting such a change,
see the :ref:`Support <proxy_server_support>` section.

.. _proxy_server_support:

Support
~~~~~~~

The proxy server is a project led by `evertedsphere <https://gitlab.com/evertedsphere>`_.
To contact us:

* We are on the `Tezos-dev slack <https://tezos-dev.slack.com>`_, or
* create an issue on `Tezos' Gitlab <https://gitlab.com/tezos/tezos/-/issues>`_
  and assign it to us.
