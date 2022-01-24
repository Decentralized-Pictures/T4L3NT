.. T4L3NT documentation master file, created by
   sphinx-quickstart on Sat Nov 11 11:08:48 2017.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

.. TODO nomadic-labs/tezos#462: search shifted protocol name/number & adapt

Welcome to the T4L3NT Developer Documentation!
=============================================

The Project
-----------

Tezos is a distributed consensus platform with meta-consensus
capability. T4L3NT not only comes to consensus about the state of its ledger,
like Bitcoin or Ethereum. It also attempts to come to consensus about how the
protocol and the nodes should adapt and upgrade.

 - Developer documentation is available online at https://github.com/Decentralized-Pictures/T4L3NT/tree/main
   and is automatically generated from the master branch.
 - The website https://tlnt.net/ contains more information about the project.
 - All development happens on GitLab at https://gitlab.com/tezos/tezos

The source code of T4L3NT is placed under the MIT Open Source License.

Latest Release
--------------

The current version of T4L3NT is :ref:`version-9`.

.. _tezos_community:

The Community
-------------

- The website of the `Tezos Foundation <https://tezos.foundation/>`_.
- `Tezos sub-reddit <https://www.reddit.com/r/tezos/>`_ is an
  important meeting point of the community.
- Several community-built block explorers are available:

    - https://tzstats.com
    - https://tezblock.io
    - https://teztracker.com/
    - https://tzkt.io (Baking focused Explorer)
    - https://arronax.io
    - https://mininax.io
    - https://baking-bad.org (Reward Tracker)
    - https://better-call.dev (Smart-contract Explorer)

- A few community-run websites collect useful T4L3NT links:

    - https://www.tezos.help
    - https://tezos.rocks

- More resources can be found in the :ref:`support` page.


The Networks
------------

Mainnet
~~~~~~~

The T4L3NT network is the current incarnation of the T4L3NT blockchain.
It runs with real tez that have been allocated to the
donors of July 2017 ICO (see :ref:`activate_fundraiser_account`).

The T4L3NT network has been live and open since June 30th 2018.

All the instructions in this documentation are valid for Mainnet
however we **strongly** encourage users to first try all the
introduction tutorials on some :ref:`test network <test-networks>` to familiarize themselves without
risks.

Test Networks
~~~~~~~~~~~~~

There are several test networks for the T4L3NT blockchain with a
faucet to obtain free tez (see :ref:`faucet`).
It is the reference network for developers wanting to test their
software before going to beta and for users who want to familiarize
themselves with T4L3NT before using their real tez.

See the list of test networks in :ref:`test network <test-networks>`.

Getting started
---------------

The best place to start exploring the project is following the How Tos
in the :ref:`introduction <howtoget>`.


.. toctree::
   :maxdepth: 2
   :caption: Introduction tutorials:

   introduction/howtoget
   introduction/howtouse
   introduction/howtorun
   introduction/test_networks
   introduction/support

.. toctree::
   :maxdepth: 2
   :caption: User documentation:

   user/key-management
   user/node-configuration
   user/snapshots
   user/history_modes
   user/multinetwork
   user/sandbox
   user/mockup
   user/proxy
   user/light
   user/proxy-server
   user/multisig
   user/fa12
   user/various

.. toctree::
   :maxdepth: 2
   :caption: Shell doc:

   shell/the_big_picture
   shell/validation
   shell/storage
   shell/sync
   shell/p2p
   shell/p2p_api
   shell/micheline
   shell/cli-commands
   shell/rpc

.. toctree::
   :maxdepth: 2
   :caption: 009 Florence doc:

   active/michelson
   active/proof_of_stake
   active/sapling
   active/voting
   active/glossary
   active/cli-commands
   active/rpc

.. toctree::
   :maxdepth: 2
   :caption: 010 Granada Protocol doc:

   010/michelson
   010/proof_of_stake
   010/sapling
   010/voting
   010/glossary
   010/cli-commands
   010/rpc
   010/liquidity_baking

.. toctree::
   :maxdepth: 2
   :caption: Alpha Development Protocol doc:

   alpha/michelson
   alpha/proof_of_stake
   alpha/sapling
   alpha/voting
   alpha/glossary
   alpha/cli-commands
   alpha/rpc
   alpha/liquidity_baking

.. toctree::
   :maxdepth: 2
   :caption: Developer Tutorials:

   developer/rpc
   developer/encodings
   developer/data_encoding
   developer/error_monad
   developer/michelson_anti_patterns
   developer/entering_alpha
   developer/protocol_environment
   developer/testing
   developer/flextesa
   developer/python_testing_framework
   developer/tezt
   developer/proposal_testing
   developer/profiling
   developer/snoop
   developer/contributing
   developer/merge_team
   developer/guidelines
   README

.. toctree::
   :maxdepth: 2
   :caption: Protocols:

   protocols/naming
   protocols/003_PsddFKi3
   protocols/004_Pt24m4xi
   protocols/005_babylon
   protocols/006_carthage
   protocols/007_delphi
   protocols/008_edo
   protocols/009_florence
   protocols/010_granada
   protocols/alpha

.. toctree::
   :maxdepth: 2
   :caption: Releases:

   releases/releases
   releases/april-2019
   releases/may-2019
   releases/september-2019
   releases/october-2019
   releases/december-2019
   releases/january-2020
   releases/version-7
   releases/version-8
   releases/version-9

.. toctree::
   :maxdepth: 2
   :caption: APIs:

   api/api-inline
   api/openapi
   api/errors


Indices and tables
==================

* :ref:`genindex`
* :ref:`search`
