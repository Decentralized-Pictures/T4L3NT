Protocol Alpha
==============

This page contains all the relevant information for protocol Alpha
(see :ref:`naming_convention`).

The code can be found in the :src:`src/proto_alpha` directory of the
``master`` branch of Tezos.

This page documents the changes brought by protocol Alpha with respect
to Protocol I.

.. contents::

Bug Fixes
---------

Minor Changes
-------------

Michelson
---------

- Some operations are now forbidden in views: ``CREATE_CONTRACT``,
  ``SET_DELEGATE`` and ``TRANSFER_TOKENS`` cannot be used at the top-level of a
  view because they are stateful, and ``SELF`` because the entry-point does not
  make sense in a view.
  However, ``CREATE_CONTRACT``, ``SET_DELEGATE`` and ``TRANSFER_TOKENS`` remain
  available in lambdas defined inside a view.
  (MR :gl:`!3737`)
