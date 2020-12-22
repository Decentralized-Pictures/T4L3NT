.. _coding_guidelines:

Coding guidelines
=================

This document provides guidelines that should be observed by all the contributors to the Tezos codebase. It first presents documentation guidelines, and then rules more specific to coding (e.g., logging levels, code formatting, naming conventions, etc.).

.. _in_code_comments:

Comments in the code
--------------------

The OCaml code should include comments facilitating the comprehension and the maintenance. In particular, the main syntactic constructs in the code should be commented as follows.

Modules:

- One-line comment explaining the purpose of the module
- If needed: More detailed description

Types:

- One-line comment explaining what the type represents, typically the invariants satisfied by its inhabitants

Functions and methods:

- Purpose of the function, brief description of the returned value
- If needed: How and why to use this function
- If needed: Pre-conditions for calling the function
- If needed: Conditions under which the function will return an error
- If needed: Any special behavior that is not obvious

Constants and struct fields:

- Purpose and definition of this data. If the unit is a measurement of time, include it, e.g., TIMEOUT_MS for timeout in milliseconds.

Documenting interfaces
----------------------

At the granularity of OCaml files, it is essential to document the interface implemented by each file.

Implementation (``.ml``) files:

- In the common case where there is a corresponding interface (``.mli``) file,
  document the interface file instead, as detailed below.
- In the less common case where there is no corresponding interface (``.mli``)
  file, document the exported elements directly in the implementation (``.ml``)
  file.

Interface (``.mli``) file comments:

- One-line description
- Brief description of the library, introducing the needed concepts
- Brief description of each module, type, function, data, as described for :ref:`comments in the code<in_code_comments>`.

README files
------------

At coarser levels, source file directories should be documented by Markdown files called ``README.md``. Such files are mandatory in top-level directories of the Tezos codebase (such as ``src/`` and ``docs/``), and at least in immediate sub-directories of the source directory (``src/*/``).

Source directories must instantiate the following ``README.md`` template::

  # Component Name
  Summary line: One sentence about this component.

  ## Overview
  - Describe the purpose of this component and how the code in this directory
    works. If needed, design rationale for its API.
  - Describe the interaction of the code in this directory with the other
    components. This includes dependencies on other components, for instance.
  - Describe the security model and assumptions about the crates in this
    directory.

  ## Implementation Details
  - Describe how the component is modeled.
  - Describe the code structure and implementation design rationale.
  - Other relevant implementation details (e.g. global invariants).
  - Testing specifics, if needed.

  ## API Documentation
  - Link to the external API.
  - For the top-level source directory, link to the most important APIs within.

The rationale of this template is that a README file addresses two different kinds of developers:

#. the users of the module, which are concerned only about the component
   concepts and API, and not about its implementations details, and
#. the developers and maintainers of the module, which are also concerned about
   implementation details.

Logging Levels
--------------

The Tezos libraries use an internal logging library with 5 different verbosity `levels`.
It is important to choose the appropriate level for each event in the code to
avoid flooding the node administrator with too much information.

These are the rules-of-thumb that we use in the code to decide the appropriate
level (here listed from most to least verbose) for each event:

- ``Debug`` level -- the most verbose -- it is used by developers to follow
  the flow of execution of the node at the lowest granularity.
- ``Info`` level is about all the additional information that you might want to
  have, but they are not important to have if your node is running OK
  (and definitely do not require any action).
- ``Notice`` level (the default) should be about things that the node
  admin should be concerned, but that does not require any action.

The two following levels are used to provide information to the node
administrator of possible problems and errors:

- ``Warning`` level are all those events that might require the attention of
  the node administrator, and can reveal potential anomalies in the workings of
  the node.
- ``Error`` level are all those events that require an intervention of the node
  administrator or that signal some exceptional circumstance.

It's also important to notice that from the node administrator's point of view,
it is possible to choose a specific log level for a given component
by setting the environment variable ``TEZOS_LOG`` accordingly while running the node.

Code formatting
---------------

To ensure that your OCaml code is well formatted, set up correctly your editor:

+ automatically run `ocamlformat` when saving a file
+ no tabs, use whitespaces
+ no trailing whitespaces
+ indent correctly (e.g. use lisp-mode for dune files)

Many of these checks can be run with ``make test-lint``.

Some of these checks can be executed with a `pre-commit <https://git-scm.com/book/en/v2/Customizing-Git-Git-Hooks>`_
which is installed with
``ln -sr scripts/pre_commit/pre_commit.py .git/hooks/pre-commit``
(see the header of `./scripts/pre_commit/pre_commit.py` and its `--help`
for additional options).
