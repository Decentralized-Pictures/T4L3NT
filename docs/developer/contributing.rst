How to contribute
=================

The purpose of this document is to help contributors participate to
the Tezos OCaml codebase.

Introduction
------------

There are several ways to get involved with the codebase, and you may want to start with some preliminary steps.


Reporting issues
~~~~~~~~~~~~~~~~

The simplest way to contribute to Tezos is to report issues that you may
find with the software on `gitlab <https://gitlab.com/tezos/tezos/-/issues>`__.
If you are unsure about an issue
consult the :ref:`technical support sources <support>`
first and always make sure
to search the existing issues before reporting a new one.
Some information that are probably important to include in the description:
the architecture (e.g. *ARM64*), the operating system (e.g. *Debian
Stretch*), the network you are connected to (e.g. *Carthagenet*), the
binary or component (e.g. *tezos-node crashes* or *rpc X returns Y
while Z was expected*).


Going further
~~~~~~~~~~~~~

To directly contribute to the codebase, expertise in a few areas is necessary.

First, make sure that you are proficient enough in OCaml. The community
website https://ocaml.org gives a few useful pointers for that. In
particular, we use a lot of functors, and a few GADTs in the codebase,
so you may want to make sure that you master these advanced concepts.

Then, if you don’t know much about the Lwt library, that’s what you want
to learn next. This library is used extensively throughout the code base:
we use it to handle concurrency. You can use the
`online documentation <https://ocsigen.org/lwt/3.2.1/manual/manual>`__. The
chapter on concurrency of the `Real World OCaml <https://dev.realworldocaml.org/>`__ book
has also been `ported to Lwt <https://github.com/dkim/rwo-lwt>`__.

After that, it is a good idea to read the tutorials for
:ref:`error_monad<error_monad>` and
:ref:`data_encoding <data_encoding>`, two homegrown
libraries that we use pervasively.

While you familiarize yourself with the basics as suggested above, you
can have a look at the :ref:`software architecture
<software_architecture>` of Tezos. It will
give you the main components and their interactions, and links to the
documentations for the various parts.

Now, that you're ready to delve into the code, it is time to know how
contributions to the code are submitted, reviewed, and finally accepted into the master branch.

Our git strategy
----------------

First of all, the repository is https://gitlab.com/tezos/tezos. So if you want
to contribute, simply create an account there.

There are many ways to use Git, here is ours.

We mostly use merge requests (aka MRs) for contributing to the master branch,
meaning that nobody should be pushing into the master branch directly. Once a
merge request is ready, it is reviewed and approved, then merged using the ``--
fast-forward`` option of Git in order to
maintain a linear history without merge commits.

For that to work, merge requests must be direct suffixes
of the master branch. So whenever ``origin/master`` changes, you have to
rebase your branch on it, so that your patches always sit on top of
master. When that happens, you may have to edit your patches during the
rebase, and then use ``push -f`` in your branch to rewrite the history.
Being proficient with interactive rebases is mandatory to avoid
mistakes and wasting time.

This Git strategy is an instance of the `git rebase workflow <https://www.atlassian.com/git/articles/git-team-workflows-merge-or-rebase>`_.

.. _mr_workflow:

Workflow of an MR
-----------------

This section presents a global view of our MR workflow. Details about the
individual steps in this workflow are described in the following sections.

Our code review process uses GitLab. First a developer creates a new
branch for :ref:`preparing the MR <preparing_MR>`.
As this is a private new branch, the developer is free to
rebase, squash commits, rewrite history (``git push --force``), etc. at will.

Once the code is ready to be shared with the rest of the team, the developer
:ref:`opens a Merge Request <creating_MR>`.
It is useful to explain why the MR is created, to
add a precise description of the code
changes, and to check if those are in line with the initial
requirements (if responding to an issue), or to the stated reasons (otherwise).
Dependencies on other merge requests, other relationships to MRs, to
issues, etc, should also be mentioned.

While the code is still not ready to be peer reviewed, but it is merely a
work in progress, the developers prefixes the MR with ``WIP:``. This will tell everybody
they can look at the code, comment, but there is still work to be done and the
branch can change and history be rewritten.

Finally, when the code is ready for the :ref:`code review <code_review>`, the developer removes the WIP status of the
MR and freezes the branch. From this moment on, the developer will refrain to
rewrite history, but he/she can add new commits and rebase the branch for
syncing it with master (this can be done regularly to make sure the branch does
not get stale). At this point the developer interacts with the reviewers to
address their comments and suggestions.

GitLab allows both to comment on the code and to add general comments on the
MR.  Each comment should be addressed by the developer. He/she can add
additional commits to address each comment. This incremental approach will make
it easier for the reviewer to keep interacting till each discussion is
resolved. When the reviewer is satisfied, he/she will mark the discussion resolved.

When all discussions are resolved, you should squash any fix-up commits that were applied (don't forget to edit the commit message appropriately).
Then, the reviewer will rebase the branch and merge the MR in the master branch.

.. _preparing_MR:

Preparing a Merge Request
-------------------------

While working on your branch to prepare a Merge Request, make sure you respect the following rules:

-  Give a meaningful and consistent name to the branch

   * It is useful to prefix the name of the branch with the name of
     the developer to make it clear at a glance who is working on what: e.g.
     ``john@new-feature``.

   * Note that some extra CI tests are only done on demand for branches other
     than master. You can (should) activate these tests by including keywords in
     the branch name.

     +  If your MR impacts OPAM packaging, use ``opam`` in the branch name.

-  Prefer small atomic commits over a large one that does many things.
-  Don’t mix refactoring, reindentation, whitespace deletion, or other style
   changes with new features or other real changes.
-  No peneloping: don't do something in a commit just to undo it two
   commits later.
-  Try as much as possible to make every patch compile, not only the last one.
-  Follow the format of commit names, `<Component>: <message>`, with
   message in indicative or imperative present mood e.g. ``Shell: fix
   bug #13`` rather than ``Shell: fixed bug #13``.
   Use multilines commit messages for important commits.
-  Adhere to the :ref:`coding guidelines <coding_guidelines>`.
-  Document your changes, in the MR description and commit messages.
   Imagine if somebody asked what your change was about in front of the
   coffee machine, write down your answer and put it in the MR.
-  If there is a design description at the top of the file, consider updating
   it to reflect the new version. Additionally, if you feel that your design
   *changes* are worth mentioning to help upcoming contributors (e.g. justify a
   non-obvious design choice), you should document them in this file header,
   but in a separate "History" section.
-  If you add new functions to an interface, don’t forget to
   document the function in the interface (in the corresponding .mli file; or,
   if there is no .mli file, directly in the .ml file)
-  Check whether your changes need to be reflected in changes to the
   corresponding README file (the one in the directory of the patched
   files). If your changes concern several directories, check all the
   corresponding README files.
-  For parts that have specifications in the repository (e.g., Michelson),
   make sure to keep them in sync with the implementation.

.. _creating_MR:

Creating the Merge Request
--------------------------

Your goal is to help the reviewers convince themselves that your patch
should be merged.
Well-documented merge requests will receive feedback faster.
Complicated patches with no comments to help the reviewer will cause
the reviewer to make the wrong decision or will discourage the
reviewer to work on the MR.

Therefore, when creating your MR, observe the following rules:

- *Give it an appropriate title*.

- *Give context*: why was this patch written?

  - Does it fix a bug, add a feature or refactor existing code?
  - Is there an open issue on GitLab, or a post from an angry user
    somewhere?
  - Must it be merged before another merge request?

- *Test*:

  - Explain how you tested your patch (or why you didn't).

  - The description of merge requests must include instructions for
    how to manually test them, when applicable.

  - Merge requests should include automated tests for new
    functionality and bug fixes.

    - Refer to the :ref:`testing guide <testing>` for more information.

    - Bug fixes should include a test that demonstrates that the bug has been fixed
      (i.e. that fails before the supplied fix).

    - The :ref:`test coverage <measuring-test-coverage>` can be used to
      guide testing of the proposed MR. If the modified code lacks
      coverage, then this indicates that tests should be added.

    - If no tests are included, a justification should be given in the
      description. Possible justifications include that testing is
      prohibitively difficult, or that the modified code is already
      well-exercised by the existing test suite. The point of the
      justification is to stress the importance of testing and to guide
      improvements of the test framework.

- *Divide and conquer*: it is easier to merge several simple commits than a big one.

  - Isolate complicated parts of your patch in their own commits.
  - Put simple, non-controversial commits first. For instance: commits
    which fix typos, improve documentation, or are simple enough that
    we may want to merge them even without the rest of the merge
    request.
    Even better put them in a separate MR which can be merged easily.
  - Split your commits so that each step is convincing on its own, like
    the proof of a big theorem which is split into several lemmas.

- *Anticipate questions*: explain anything which may look surprising, as comments in the code itself if it has value to future readers, or in the MR description.

- *MR Labels*: Add GitLab labels to the MR, like ``doc`` or ``protocol``.
- *MR Options*: When opening an MR you should probably tick the following
  options:

  + `Delete source branch when merge request is accepted.`
    Helps keeping the repository clean of old branches.
  + `Squash commits when merge request is accepted.`
    Sometimes it's useful to have many small commits to ease the
    review and see the story of a branch, but they are not relevant
    for the history of the project. In this case they can be squashed
    and replaced with a single meaningful commit. Nevertheless, you
    should squash yourself all fix-up commits when all discussions are resolved,
    as described above in the :ref:`MR workflow <mr_workflow>`, in order
    to ease the reviewers' task.
  + `Allow commits from members who can merge to the target branch.`
    This option is useful to allow members of the merge team, who are
    not developers in your project, to commit to your branch.
    It helps to rebase and propose fixes.

- *Find reviewers*: it is the responsibility of the author to find a
  suitable reviewer, ideally before opening an MR. The reviewer(s)
  should be mentioned in the description or in the comments.

- *Check progress*:
  It is important to maintain to a minimum the number of your MRs that are in WIP state,
  and to constantly check that the discussion is progressing.

Example of an MR with a good, clean history (each bullet is a commit,
any subitems represent the longer description of that commit)::

  * Doc: mark bug #13 as fixed
  * Test_python: add test for p2p bug #13
  * Flextesa: add test for p2p bug #13
  * Shell: fix p2p bug #13
    - fix bug in the shell
    - fix relative unit test
    - add docstrings

**Beware**: No MR targeting the ``master`` should touch
``src/proto_alpha/lib_protocol`` (see :ref:`protocol MRs <protocol_mr>`)

.. _protocol_mr:

Protocol development MRs
------------------------

Because of the amendment procedure that governs the protocol, the
workflow for protocol development is significantly different from
master.

All work on the protocol is done in the branch ``proto-proposal``, which
is regularly rebased on master.
Before a proposal, a new branch, e.g. ``proto-005-PsBabyM1``, is
created from ``proto-proposal`` where the development continues.
When and if ``proto-005-PsBabyM1`` is activated, it is then merged
into master.

The hash of the protocol is computed from the directory
``src/proto_alpha/lib_protocol``, so every change in this directory
should happen in the branch ``proto-proposal``.
MRs that touch the client or daemons in ``src/proto_alpha/`` should be
merged in master, except if they depend on a new protocol feature, in
this case they go to ``proto-proposal``.
Make an effort to split your MR so that a maximum of code can be
merged in master.

The Migration
~~~~~~~~~~~~~

Right before the activation of a new protocol, there is a migration of
the context that takes place.
This migration typically converts data structures from the old to the
new format.
Each migration works exclusively between two protocol hashes and it is
useless otherwise.
For this reason after the activation of a protocol the first step to
start a new development cycle is to remove the migration code.
In order to facilitate this, *migration code is always in a different commit* with respect to the protocol features it migrates.
When submitting an MR which contains migration code, **the author must also have tested the migration** (see :ref:`proposal_testing`) and write in the
description what was tested and how so that **reviewers can reproduce it**.

Shape of commits
~~~~~~~~~~~~~~~~

In order to ease rebasing and reworking the history, **we don't expect
every commit to compile and pass tests**.
We prefer to keep commits small and local to a component.
Note that we do expect tests to pass between each MR.

A typical MR for ``proto-proposal`` would look like this (each bullet is a
commit, any subitems represent the longer description of that commit)::

  * Tests_python: test that no block is produced during a weekend
  * Flextesa: test that no block is produced during a weekend
  * Proto/test: test that no block is produced during a weekend
  * Proto/Baker: skip weekend when producing blocks
  * Proto/Migration: migrate table of rights to remove weekends
  * Proto: stop block production during weekends
    + block submitted during a weekend fails application
    + adapt computation of rights
    + add RPC to check weekends

Right after the change to the protocol, the code might not compile,
because the baker is not fixed yet.
After the baker commit, the test might not pass because of a change in
behavior.


.. _code_review:

Code Review
-----------

At Tezos all the code is peer reviewed before getting committed in the
master branch by the :ref:`merge team <merge_team>`.
Briefly, a code review is a discussion between two or
more developers about changes to the code to address an issue.

Author Perspective
~~~~~~~~~~~~~~~~~~

Code review is a tool among others to enhance the quality of the code and to
reduce the likelihood of introducing new bugs in the code base. It is a
technical discussion; not an exam, but rather a common effort to learn
from each other.

These are a few common suggestions we often give while reviewing new code.
Addressing these points beforehand makes the reviewing process easier and less
painful for everybody. The reviewer is your ally, not your enemy.

- Commented code: Did I remove any commented out lines?
  Did I leave a ``TODO`` or an old comment?

- Docstrings: Did I export a new function? Each exported
  function should be documented in the corresponding ``mli`` (or directly in the ``ml`` file if there is no ``mli``).

- README: Did I check whether my changes impact the corresponding README
  file(s)?

- Readability: Is the code easy to understand? Is it worth adding
  a comment to the code to explain a particular operation and its
  repercussion on the rest of the code?

- Variable and function names: These should be meaningful and in line
  with the conventions adopted in the code base.

- Testing: Are the tests thoughtful? Do they cover the failure conditions? Are
  they easy to read? How fragile are they? How big are the tests? Are they slow?

- Are your commit messages meaningful? (see https://chris.beams.io/posts/git-commit/)

Review your own code before calling for a peer review from a colleague.

Reviewer Perspective
~~~~~~~~~~~~~~~~~~~~

Code review can be challenging at times. These are suggestions and common
pitfalls a code reviewer should avoid.

- Ask questions: How does this function work? If this requirement changes,
  what else would have to change? How could we make this more maintainable?

- Discuss in person for more detailed points: Online comments are useful for
  focused technical questions. In many occasions it is more productive to
  discuss it in person rather than in the comments. Similarly, if discussion
  about a point goes back and forth, It will be often more productive to pick
  it up in person and finish out the discussion.

- Explain reasoning: Sometimes it is best to both ask if there is a better
  alternative and at the same time justify why a problem in the code is worth
  fixing. Sometimes it can feel like the changes suggested are nit-picky
  without context or explanation.

- Make it about the code: It is easy to take notes from code reviews
  personally, especially if we take pride in our work. It is best to make
  discussions about the code than about the developer. It lowers resistance and
  it is not about the developer anyway, it is about improving the quality of
  the code.

- Suggest importance of fixes: While offering many suggestions at once, it is
  important to also clarify that not all of them need to be acted upon and some
  are more important than others. It gives an important guidance to the developer
  to improve their work incrementally.

- Take the developer's opinion into consideration: Imposing a particular design
  choice out of personal preferences and without a real explanation will
  incentivize the developer to be a passive executor instead of a creative agent.

- Do not re-write, remove or re-do all the work: Sometimes it is easier to
  re-do the work yourself discarding the work of the developer. This can give
  the impression that the work of the developer is worthless and adds
  additional work for the reviewer that effectively takes responsibility for
  the code.

- Consider the person you are reviewing: Each developer is a person. If you
  know the person, consider their personality and experience while reviewing their
  code. Sometime it is possible with somebody to be more direct and terse, while
  other people require a more thorough explanation.

- Avoid confrontational and authoritative language: The way we communicate has
  an impact on the receiver. If communicating a problem in the code or a
  suggestion is the goal, making an effort to remove all possible noise from
  the message is important. Consider these two statements to communicate about
  a problem in the code : "This operation is wrong. Please fix it." and
  "Doing this operation might result in an error, can you please
  review it?". The first one implies you made an error (confrontational), and
  you should fix it (authority). The second suggest to review the code because
  there might be a mistake. Despite the message being the same, the recipient might
  have a different reactions to it and impact on the quality of this work. This
  general remark is valid for any comment.

The Merge-Request Bot
---------------------

Every 6 hours, an automated process running as the
`Tezbocop <https://gitlab.com/tezbocop>`__ 🤖 user, inspects recent MRs and posts
or edits comments on them, giving an inspection report on the contents of the
MR.

Some warnings/comments are for you to potentially improve your MR, other
comments just help us in the assignment & review process.

The first time Tezbocop posts a message you should receive a notification; for
the subsequent edits there won't be notifications; feel free to check Tezbocop's
comments any time.

If you think some of the remarks/warnings do not apply to your MR feel free to
add a comment to justify it.

In particular, the Merge-Request Bot may complain about TODOs but they aren't
strictly
forbidden, if they alert the reader that some code is a short-term solution
but could be improved in the future.

The code for the bot is at
`smondet/merbocop <https://gitlab.com/smondet/merbocop>`__. It is of course
work-in-progress and new warnings and comments will appear little by little.
We welcome specific issues or contributions there too.
