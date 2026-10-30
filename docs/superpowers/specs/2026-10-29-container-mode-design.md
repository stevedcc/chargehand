# Container mode: Chargehand on an always-on box

Status: draft for the owner's review (2026-10-29). Written from a brainstorming conversation with
the owner. Every statement is marked with its source:

- **(owner)** means the owner decided it;
- **(call)** means the orchestrator decided it and the owner should check it;
- everything else is context or constraint.

## Intent

Today Chargehand needs the owner's desktop to run: Claude Code orchestrates there, OpenCode runs in a
bubblewrap sandbox as a separate agent user, and Claude subagent implementers run as the owner. The
owner wants the desktop **off at night** while the work keeps moving. That means a small always-on
machine (first: a fanless router's VM, 3 E-cores) that runs the whole routine unattended:

- launch the queued briefs;
- watch them;
- review, verify and read the diffs;
- merge, tag and release.

The owner wakes up to finished work, a live release and a short summary.

Container mode is a Chargehand feature, not a one-machine setup **(owner)**. Nothing in this
document may depend on a particular host, address or user name.

## Goals

1. **The whole orchestrator runs on the box (owner).** It covers the same scope as a supervised
   evening today: launching briefs, external reviews, verify, the diff read, merging PRs, tagging
   releases. Deployment then happens as it does now: the project's own release pipeline and GitOps
   pick up the tag.
2. **Every role in its own container, with only the access its job needs (owner).** There are four
   roles: orchestrator, Claude implementer, OpenCode, and runner (details under Architecture).
3. **The container runtime is a setting (owner):** Docker, Podman or Apple's `container` tool.
4. **Images for arm64 and amd64 (owner),** so a Mac can join later.
5. **Briefs run on all configured machines at once (owner).** The router box, the owner's desktop
   and, later, the owner's Mac are lanes. One orchestrator spreads the queue across every lane that
   is up, so several briefs run in parallel, each on its own machine. The first deployment is the
   router box (one brief at a time there **(call)**), but the scheduler, lanes and channels are
   built for several machines from the start, not added later.
6. **Questions reach the owner's phone (owner).** A brief that needs a decision pings the owner and
   waits for a timeout. Then it parks and the night moves on to the next brief.
7. **The owner owns the queue (owner).** The owner decides what goes into the night's queue and in
   what order. The box never picks up work on its own.
8. **The orchestrator keeps the toolchains current (owner).** It can update the SDKs and installed
   software of every container on every lane: for example the .NET SDK when a project's
   `global.json` moves, Playwright's browsers, OpenCode, Claude Code. See "Updating the images".
9. **A morning summary.** It lists what merged, what was released, what is parked and why, and the
   cost.

## Non-goals

- **Picking work from the backlog board.** It is a possible later extension **(owner)**.
- **A shared, synchronised secrets vault.** The interim is a duplicate vault **(owner)**; see
  Secrets.
- **Write access to the cluster from the box.** Deployment goes through the project's GitOps.
- **Running two briefs at once on the 3-core box** **(call: memory and CPU; two suites at once have
  taken a 32 GB desktop down twice)**. Parallelism comes from more machines, not from overloading
  one.
- **Replacing the desktop flow.** The bubblewrap sandbox and the desktop orchestrator keep working.
  Container mode is a second way to run, chosen per machine.

## Anti-goals (failures even if everything "works") (owner)

1. **Exposed secrets.** A secret ends up in a log, a transcript, a branch, an image, or a container
   that runs untrusted code.
2. **Tests rewritten to suit the code.** An assertion is weakened or changed so that wrong code
   passes, and the change merges unattended.
3. **Auth breaking.** A change opens anonymous access to admin pages, editor pages or write
   endpoints, and it gets released.

Each anti-goal has a hard rule in "Unattended merge gates" and "After a release" below.

## Architecture

### Roles and trust

| Container | Trust | Runs | Holds | Network |
|---|---|---|---|---|
| **Orchestrator** | trusted | Claude Code with Chargehand, the queue, merge/tag/release, notifications | vault access (hardware key passed through), GitHub write credentials, the runtime's control socket | outbound |
| **Claude implementer** | semi-trusted | one headless Claude Code session per brief, in that brief's worktree only | a Claude login (see Secrets); no vault, no GitHub write access | outbound, to the model API at least |
| **OpenCode** | semi-trusted | the OpenCode server: external reviews (and implementers, if the project uses them) | the model plans' API keys; no vault, no GitHub write access | outbound, to the model APIs |
| **Runner** | untrusted | builds and tests for verification: a clean checkout of the exact SHA, the project's root-owned commands | nothing | outbound only while restoring packages, none during build and tests (see "Runner network"); a private network to its service containers |

- **Who controls the runtime.** Only the orchestrator talks to the container runtime. No other
  container gets a runtime socket: a socket that can start containers is host access for that user.
- **Service containers.** Postgres, the mock IdP and similar are started by the orchestrator per
  verify, on a private network made for that run, and removed afterwards. This also ends
  concurrent E2E runs sharing one IdP.
- **Implementers stop being subagents (owner, consequence).** On the box, Claude implementers become
  separate headless sessions, not subagents of the orchestrator. The orchestrator watches them the
  way it watches OpenCode sessions today: the session tree, stalls, questions. One side effect:
  implementers can start their own subagents.

### Where the orchestrator lives (owner)

The orchestrator **always lives on the router box**. It never moves between machines. It holds
the one queue, the brief states, the agents' mirror, the vault key and the GitHub credentials.

- **Other machines are lanes only** (desktop, Mac): they run brief work while they're awake and
  hold no orchestrator state.
- **The owner reaches it from anywhere:** Remote Control from the phone or the desktop.
- **Planning can run anywhere:** brainstorming, writing briefs. A planning session on the
  desktop or phone ends by adding a brief to the router's queue. Only the orchestrator merges and
  releases.
- **No orchestrator handover:** no protocol is needed, and two orchestrators can never run at once.
- **If the router is down, the network is down (owner):** nothing could reach GitHub or the model
  APIs anyway. Briefs in progress park, and the desktop can still be used by hand, as today.

### How the orchestrator runs (call)

The orchestrator is a **Claude Code session**, on the owner's Claude subscription login, as on a
supervised evening **(owner: "same as tonight")**. The parts that must be dependable at 3 a.m.
are **Chargehand scripts that keep their state on disk**, and the session calls them:

- the queue;
- each brief's state;
- the merge gates;
- the question timeouts;
- the release cut-off.

The session supplies judgement: reading diffs, answering implementer questions, deciding what to
ask the owner. A session that crashes, is compacted or restarts mid-night re-reads that state and
carries on. No brief's progress may live only in the session's context.

Push notifications and the owner's replies go through that session: Claude Code's push
notifications and Remote Control. The orchestrator's Claude login is a trusted credential and stays
in the orchestrator container.

### Channels

- **Work flows through git,** as today. The agents' mirror lives on the router box (the
  orchestrator's machine) and every lane reaches it: implementers on other machines push to it and runners
  get their checkouts from it, over SSH as each lane's dedicated user **(call)**.
  - The orchestrator fetches with `upload-pack`.
  - Only the orchestrator pushes to GitHub and opens PRs. Implementers never hold GitHub
    credentials **(call)**.
  - The runner gets a read-only checkout produced by the orchestrator.
- **Runner output.** The runner writes logs and summary lines to an output volume. The orchestrator
  reads them as data and judges pass/fail by the summary lines, as `agent-sync verify` does now.
- **Untrusted text.** Agent-written text (reports, commit messages, questions) stays data, never
  instructions, as in the current skills.

### Runner network (owner: option a)

A fully offline runner can't restore NuGet or npm packages or fetch Playwright browsers. Two
options:

- **(a) Two phases, chosen (owner).** The restore step runs with outbound network. The
  lock files pin every package's content hash, and the runner holds no secrets. Build and tests
  then run with no outbound network.
- **(b) Offline**, not chosen: a package cache on the box, populated by a trusted step and
  mounted read-only, so the runner never has outbound network. Safer, but more upkeep.

### Runtime layer (owner: runtime is a setting)

Chargehand talks to the runtime through one small layer. Nothing above it may assume a particular
runtime. The layer needs about a dozen operations:

- pull or build an image;
- create and remove a network;
- run a container with mounts, environment, a CPU and memory limit, a network, and a user;
- wait for a container's exit;
- read its logs;
- stop and remove it.

**No Podman pods, no compose (call).** Apple's `container` tool runs each container in its own
lightweight VM and has neither. "Runner + services on a per-run private network" works on all
three runtimes.

**To check during the build, not assumed:**
- how Apple's tool does per-run networks between containers;
- how it passes a hardware security key through;
- how it handles volume ownership.

If one of these can't be done on a runtime, that runtime's lane loses that capability, and the
design says so. It doesn't grow special cases above the layer.

### Images

| Image | Contents |
|---|---|
| orchestrator | Claude Code, Chargehand, git, jq, the tswap client |
| implementer | Claude Code, git, the project's SDK (for the implementer's own red/green loops) |
| opencode | OpenCode 2.x with Superpowers |
| runner | per project: pinned SDK and browsers. For the reference project: the .NET SDK from `global.json` plus Playwright's browsers |

- **Architectures:** every image is built for arm64 and amd64 **(owner)**.
- **Version pins:** images are rebuilt when the project's pins move (SDK, Playwright).
- **Where images are built (call):** on a trusted host or in CI, published to a registry the
  owner controls. The box only pulls them.

### Updating the images (owner: the orchestrator can update every container)

**Updates are new images, never installs into running containers (call).** Software installed into
a running container is lost on restart and leaves lanes slightly different from each other.

1. **Change:** the orchestrator commits the change to the image definitions: a version pin, a
   new SDK, a new tool. The image definitions live in a repository it can push to.
2. **Build:** CI (or the trusted build host) builds the images for both architectures and publishes
   them.
3. **Roll out:** the orchestrator tells each lane's controller to pull the new image and use it for
   every container started from then on.

Rules:

- **Between briefs only:** a container in use is never replaced mid-brief. New briefs and new
  verifies get the new image; running ones finish on the old one.
- **Pinned by digest:** lanes use images by digest, and every verify records the digests it ran
  on, so a result can be traced to the exact toolchain.
- **Prove it before relying on it:** after an update, the orchestrator runs one verify of `main`
  on each lane before giving that lane new briefs. On failure it rolls the lane back to the
  previous digest and notifies the owner.
- **Triggers:** the orchestrator updates when a project's pins move (a Renovate PR or a brief
  that bumps `global.json` or Playwright) or when the owner asks. It doesn't update on a schedule
  by itself **(call)**.
- **Scope:** the box's own operating system and the container runtime are not part of this. They
  stay the owner's (sudo). The orchestrator updates only what runs inside the containers.

### Lanes

A lane is one machine's configuration:

- its runtime;
- its architecture;
- cores and memory available to briefs;
- how many briefs it runs at once;
- whether it may run trusted-only test categories.

**Scheduling (owner: all machines at once).** The scheduler gives each queued brief to a free lane
as soon as one is free, preferring the faster lane. Every lane works at the same time.

- **A brief stays on its lane:** its implementer container, its verify runner and its services all
  run on the machine it was given **(call)**. Only the mirror and the orchestrator are shared.
- **Lanes come and go:** the desktop or the Mac can be off, asleep or travelling. A lane that is
  unreachable gets no new briefs. A brief whose lane disappears mid-run parks with its last state;
  it is not moved to another machine automatically **(call)**.
- **Each machine has its own controller:** the only process that touches that machine's container
  runtime. The orchestrator asks it over SSH to start, watch and stop that lane's containers.
- **Suite lock:** each machine keeps its own suite lock, so one machine never runs two suites at
  once whatever the scheduler does.
- **Conflicts:** parallel briefs are test-merged early with `integrate.sh`, as on the desktop
  today. Merges into `main` happen one at a time, through the orchestrator, with the "merge `main`
  in and verify again" rule for every later brief.
- **Lane order:** the router box first. The desktop as a lane on days it is on. The Mac once its
  runtime (Apple's `container` tool or Podman) passes the runtime-layer checks.

## The night

### The queue (owner)

The owner writes the queue: an ordered list of briefs, each committed on its `brief/<tag>` branch
as today, with its model roles and E2E instance range.

- **Who runs it:** the orchestrator takes the queue top to bottom.
- **Dependencies:** a brief may declare that it waits for another brief to merge first. Without
  that, the order is the queue's order.
- **Format:** left to the builder (a file in Chargehand's state directory is the obvious choice).

### A brief's states

`queued → implementing → reviewing → verifying → gates → merged` or
`→ parked (waiting for the owner)` or `→ failed`.

- **Released** is a property of the night, not of a brief: one release can carry several merged
  briefs.
- **Parked briefs:** a parked brief keeps its worktree, branch and notes, so the owner (or the
  next night) resumes it. A brief that depends on a parked brief parks too.
- **Moving `main` (call):** when `main` has moved since a brief's verify, the orchestrator merges
  `main` into the brief's branch (never a rebase, as today) and verifies again. On a conflict the
  brief parks; nothing is resolved automatically overnight.
- **Quota (call):** when a role's model runs out of quota, the existing fallbacks in `models.json`
  apply. When every reviewer for a role is out, the brief parks. A review by Claude alone (the
  implementer's family) is not enough for an unattended merge.
- **Failed briefs:** a failed brief is reported with its evidence. Nothing is retried blindly
  overnight.

### When it needs the owner (owner)

1. **Ping.** The orchestrator sends a push notification to the owner's phone: the brief, the
   question, the options, one line each.
2. **Reply.** The owner can answer from the phone (Claude Code's Remote Control, as used on
   2026-10-28). The brief continues with the answer.
3. **Timeout.** With no answer within the timeout (default **30 minutes** **(call)**, configurable),
   the brief parks and the orchestrator starts the next queued brief.
4. **No guessing (call).** Nothing irreversible happens on a guess: no reply means no merge and no
   release for that brief.

### Unattended merge gates (owner's anti-goals made mechanical)

A brief merges unattended only if **all** of these hold. Otherwise it parks for the morning, with
the reason:

1. Every review passed, all required CI checks are green, and the verify on the box passed on the
   exact SHA.
2. **No existing assertion changed or was removed** (anti-goal 2). New tests are fine.
   - **What counts:** a diff hunk that edits or deletes a line in an existing test file containing
     an assertion (the project names its assertion patterns in its config, for example `Should()`,
     `Assert.`, `Expect(`).
   - **Erring:** the check must err toward parking. A refactor that moves an assertion parks; the
     owner decides in the morning. So does a test-input change the brief itself asked for, which
     the project's rules allow when said in the commit message **(call)**.
3. **No change to authentication, authorisation, CSP or security headers** (anti-goal 3).
   - **How it's checked:** a per-project list of paths and patterns (for the reference project: the
     auth setup, authorisation attributes, the CSP builder, the cookie and token code).
   - **Reviews don't override it:** a hit parks the brief whatever the reviews say.
4. **No trusted-only test category needed.** If the brief touches files that require the project's
   trusted-only tests, it parks: for the reference project, Dockerfiles, migration-retry code and the
   `migrate` entries require the `Container` and `ReadyToRun` categories, which build images and
   need a runtime socket. The runner can't provide that.
5. **No secret in the diff.** The repository's push protection is the second net, not the first.

### Release

- **When:** the orchestrator releases the way the project releases. For the reference project
  that is a tag on a green `main` commit, then `release.yml`, then GitOps.
- **How often:** at most one release per night **(call)**, after the last brief that will merge
  that night, or at a configured cut-off time. Several merges ship together.

### After a release (anti-goal 3)

- **Canary:** an anonymous canary runs against the live site once the new version is serving. It
  requests a project-configured list of protected URLs (admin pages, editor pages, write endpoints)
  without credentials, and each must refuse (401, 403, or a redirect to sign-in, as configured).
  - **On failure:** notify the owner at once, stop releases for the rest of the night, and park any
    further merges.
- **Rollback:** the box has no cluster credentials. How it stops a bad release is left to the
  builder within that constraint. One option: a commit to the site's GitOps repository that
  suspends image automation and pins the previous version. It must be possible from the box's
  GitHub access alone, and the owner should approve the mechanism before it's built.
- **"Serving":** detected from the version the site reports (its footer or a version endpoint), not
  from the tag.

### Morning summary

One message (and a file in the records directory) covering:

- merged briefs with their PRs;
- the release and the canary result;
- parked briefs with their reason and the question, first;
- failed briefs with their evidence;
- cost per plan;
- anything that went wrong with the box itself (disk, memory, a stuck container).

The retro is still written with the owner, from this summary.

## Secrets

**Vault (owner):**
- The orchestrator reaches tswap through a hardware key of its own, passed through to the
  orchestrator container only.
- The box's key has a slot **without touch** **(owner)**. tswap's challenge-response needs no PIN,
  so the orchestrator can unlock the vault unattended, also after a restart.
- Interim: a **duplicate vault**, filled by hand with what overnight work needs. Drift between the
  owner's vault and the box's is accepted until tswap's key wrapping (already implemented,
  untested) lets one vault be opened by several keys.
- Nothing in this design may assume the duplicate vault is permanent.

**Credentials by container:**
- **Orchestrator:** GitHub credentials able to push, merge and tag in the project's repositories,
  and nothing for the cluster.
- **OpenCode:** gets only its plans' API keys.
- **Claude implementer:** needs a Claude login, and it runs code from its own branch. That login
  is the one credential exposed to untrusted code.
  - **To check during the build:** whether Claude Code supports a separate, scoped token for
    headless sessions. If it does, use it. If it doesn't, say so and stop for the owner's decision
    rather than mounting the orchestrator's login (call).
- **Runner:** gets nothing.

**Leak prevention:** no secret on a command line, in an environment that a log prints, or in a
transcript. tswap's existing rules apply.

## Project-side requirement (the reference project, a separate brief)

The reference project's integration tests start Postgres through Testcontainers, which needs a
runtime socket the runner must not have.

- **What the project needs:** a way to use an externally provided database. The test fixture uses
  a connection string from an environment variable (for example `CROFT_TEST_POSTGRES`) when it is
  set, and behaves as today when unset.
- **Who provides it:** the orchestrator's per-run Postgres serves it.
- **What stays on a trusted host:** the `Container` and `ReadyToRun` categories.
- **For other projects:** Chargehand documents this as a requirement of container mode.

## Sizing (call, to be measured)

The first box has 3 E-cores and about 19 GB after the owner adds ~12 GB **(owner)**.

- **Memory:** one full verify of the reference project (build, two unit/integration suites,
  three-instance E2E with browsers, Postgres, mock IdP) should fit.
- **Time:** about 2–3× the desktop's ~15 minutes.
- **Concurrency:** one brief at a time. A night carries roughly a five-brief set.
- **Measure, don't assume:** the first nights should record peak memory and wall time per brief,
  so the concurrency setting is based on measurement.

## Dependencies and order

1. The box: a dedicated user with rootless Podman (not an admin user), and the extra RAM. These are
   owner steps (sudo).
2. The runtime layer and the runner image in Chargehand, plus the reference project's external-DB
   fixture (a Croft brief). These can run in parallel.
3. Verify on the box: compare one verify against the desktop's on the same SHA. This is the first
   milestone, because it adds a lane even before the orchestrator moves.
   - **How the desktop uses that lane (call):** the desktop orchestrator asks the box's own
     controller to verify a SHA, over SSH as the box's dedicated user. Only the controller on the
     box talks to the box's runtime, so "only the orchestrator talks to the runtime" holds per
     machine.
4. The implementer and OpenCode containers; implementers as watched sessions.
5. The orchestrator container: hardware-key passthrough, the duplicate vault, the queue, gates,
   notifications, release, canary, summary.
6. A supervised first night (the owner awake, the orchestrator running on the box), then
   unattended nights.

## Left to the builder

- The queue and state file formats.
- The runtime layer's interface.
- How images are versioned and published (within "built on a trusted host or CI").
- The exact assertion and security-path heuristics. The defaults must err toward parking.
- The summary's layout.
- Logging and metrics for the box itself.
- How a stuck container is detected and cleaned up.

## Calls made in this document (owner to check)

- One brief at a time on the 3-core box.
- No pods or compose; per-run private networks instead.
- Images built off-box and pulled.
- 30-minute default timeout; no reply means no merge.
- At most one release per night.
- Merge gates 2–5 as mechanical checks that park rather than judge.
- Trusted-only test categories force a park.
- A missing scoped Claude token stops the build for the owner's decision.
- The rollback mechanism needs the owner's approval before it's built.
- The orchestrator is a Claude Code session; queue, states, gates and timeouts are scripts with
  on-disk state.
- Only the orchestrator pushes to GitHub; the mirror lives on the router box and every lane reaches
  it over SSH.
- A brief stays on its lane; an unreachable lane parks its brief instead of moving it.
- Moving `main` is merged in and re-verified; conflicts park; dependants of parked briefs park.
- All reviewers out of quota means park; Claude alone doesn't count for an unattended merge.
- Gate 2 also parks test-input changes the brief asked for.
- The desktop reaches the box's lane over SSH, through the box's controller.
- Toolchain updates are new images, rolled out between briefs and proven by one verify of `main`
  per lane; no installs into running containers; no scheduled updates; the host OS and runtime stay
  the owner's.
