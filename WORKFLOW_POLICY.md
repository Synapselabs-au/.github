# GitHub Actions and protected delivery policy

This policy defines the organization-wide baseline for GitHub Actions,
protected branches, runner trust, cost control, and workflow cleanup. GitHub
does not automatically inherit or enforce this file. Adoption requires the
repository settings and repository-local references listed below. A repository
may add stricter requirements in its own `AGENTS.md`, contribution guide,
architecture decisions, or release runbook.

## Objectives

- Development must not stop because routine workflow spend reaches a normal
  operating limit.
- Required checks must validate the current pull request and must not be
  bypassed, forged, or satisfied by an obsolete commit.
- Expensive work runs only when it changes a merge or release decision.
- Untrusted repository code never executes on a persistent shared machine.
- Every workflow has an owner, a stable purpose, a bounded runtime, and a
  documented retirement path.

## Protected branch model

All integration and production branches must:

- require pull requests, including for administrators;
- require the branch to be current before merge;
- require conversation resolution;
- block force pushes and branch deletion;
- bind required checks to the expected GitHub App where GitHub supports it;
- keep required check names stable until protection is updated atomically.

Recovr, BoltScope, and Fork use topic branch to `dev`, followed by a deliberate
`dev` to `main` promotion. The Synapse Labs website and organization `.github`
repository use reviewed topic branches directly into protected `main`.

Repository settings are enforcement. Documentation and agent prompts explain
the contract but do not replace protection.

## Trigger policy

Expensive validation should run for pull requests into an integration or
production branch. Do not repeat the same complete suite on the protected
branch push when strict, current-branch protection already validated the merge
result. Keep a post-merge push job only when it provides a distinct signal,
such as deployment, migration verification, or browser coverage not exercised
before merge.

Use explicit pull request activity types. At minimum, account for opened,
reopened, `synchronize`, `ready_for_review`, `converted_to_draft`, `edited`, and
closed events when those events affect validation or cancellation. Detect a
base-branch edit from `changes.base` in the `edited` event payload. A repository
using a merge queue must also run each required check on `merge_group`.

Do not use workflow-level path exclusions for a required workflow. A required
workflow that never starts can remain pending forever. Put conservative
change classification inside an always-created stable job, then use a cheap
validation lane for documentation-only changes.

Draft pull requests must not accidentally satisfy required checks through
skipped jobs. Use a cheap blocking path, or keep draft workflows non-required
with a separate stable gate that cannot report green until the pull request is
ready.

## Concurrency and stale runs

Every workflow must define concurrency. Pull request runs should be grouped by
workflow and pull request number, with superseded first attempts cancelled.
Manual reruns must not be able to cancel validation for a newer head. Closed
pull requests should cancel their active work.

For a pull request workflow, use the pull request number in the concurrency
group and make cancellation conditional on `github.run_attempt == 1`. Include
`closed` in the trigger types and guard expensive jobs with
`github.event.action != 'closed'`. This lets a new head or close event cancel
older work without allowing a manual rerun of an old event to cancel the current
head. Every manual rerun must still compare its event head to the live head
before allocating an expensive runner.

Before allocating an expensive runner, compare the event head with the live
pull request head when the repository's threat and cost model warrants it. A
stale rerun must fail cheaply and must never publish a required result for the
current head.

## Job design and limits

Keep cheap feedback separate from expensive validation when that avoids work
without duplicating dependency installation. Typical cheap checks are lint,
type checking, unit tests, workflow policy, and documentation validation.
Typical expensive checks are Apple platform builds, browser matrices,
integration suites, production builds, and deployments.

Every job must have a timeout based on measured runtime. Ten to fifteen minutes
is the normal range. A platform suite may use a higher bound when measured cold
runs justify it. Review timeout and p95 runtime together each quarter.

Do not split a fast single job into many jobs when repeated checkout,
dependency installation, and per-job minute rounding would cost more than the
parallelism saves.

## Permissions and supply chain

- Default workflow permissions to read-only and grant narrower write access at
  job level only when required.
- Set `persist-credentials: false` on every checkout in a job that executes
  untrusted code. Perform an authenticated Git mutation in a separate trusted
  workflow or isolated job with the minimum required permission. A checkout in
  a job that never loads or executes untrusted content may retain credentials
  only when a documented trusted step requires them.
- Pin every action to a full 40-character commit SHA and retain a version
  comment for maintainability.
- Prefer GitHub-owned actions. Every third-party action needs an explicit
  repository rationale and an immutable pin.
- Never expose production secrets to pull request code.
- Never use `pull_request_target` to execute code from an untrusted pull
  request checkout.
- Group compatible GitHub Actions dependency updates to reduce full-suite pull
  request fanout.

Organization-wide SHA enforcement may be enabled only after every active
workflow is compliant. A repository that introduces a floating action ref
must be corrected before its workflow can be treated as release-ready.

## Hosted, self-hosted, and Apple runners

Use GitHub-hosted Linux runners for routine private-repository checks when the
cost is lower than securely operating a runner fleet. Do not move Linux work
to a personal Mac solely to avoid a small hosted charge.

Untrusted pull request code may use a self-hosted runner only when each job
runs in a disposable VM or equivalent isolated worker that is destroyed after
the job. The worker must have no personal data, host mounts, Docker socket,
SSH agent, signing key, production credential, reusable repository token, or
passwordless host administration.

Such a worker must use ephemeral or just-in-time registration in a restricted
runner group. Its network policy must deny private subnets, cloud metadata,
runner-control infrastructure, and adjacent hosts, while allowing only bounded
egress required by the job. Images must be patched and immutable. Logs must be
exported outside the worker, and destruction must be verified after every job.

The shared Mac mini is not an acceptable persistent runner for untrusted pull
request code. Recovr uses its cost-bounded hosted bridge until Apple Developer
access permits migration to Xcode Cloud. Xcode Cloud then becomes the preferred
Apple build service, with exact protected status integration retained.

## Vercel and deployment builds

Do not build an application twice inside one workflow. Browser tests should
reuse an existing verified build where the framework supports it.

Vercel previews remain useful for user-interface changes. A repository may
skip Vercel builds for proven documentation-only changes through a fail-safe
ignored-build command. Do not disable topic previews broadly.

## Budgets, retention, and measurement

The organization Actions hard budget is US$100 with stop usage enabled. Native
alerts remain enabled at GitHub's supported 75, 90, and 100 percent thresholds.
The budget is emergency protection, not normal workflow control.

The default artifact and log retention is 14 days. Release evidence or an
active incident may use longer retention when documented. Workflows must not
upload credentials, personal health data, production exports, or other
sensitive material as artifacts.

Review the following at least quarterly and after any cost incident:

- minutes and cost by repository, workflow, runner type, and event;
- cancelled, failed, queued, and timed-out minutes;
- duplicate pull request and protected-branch runs;
- matrix size, schedule frequency, cache size, and artifact byte-days;
- p50 and p95 job duration;
- Vercel and other provider builds that duplicate GitHub work.

Every material optimization must record its measured baseline, expected
saving, safety constraints, and post-change canary result. Estimates are not
reported as realized savings until live runs confirm them.

## Cleanup and incident response

Workflow-owned temporary checkouts, DerivedData, simulator data, containers,
bundles, credentials, and worker-local caches must be bounded and removed after
each run. Keep cleanup scoped to exact task-owned paths. Managed dependency
caches may persist when their keys are immutable, their size and retention are
bounded, and sensitive material is excluded. Preserve failure evidence only for
the documented retention window, then remove it automatically.

If a required check cannot start because of billing, runner capacity, or
provider failure, record the infrastructure blocker and restore capacity. Do
not weaken branch protection or publish a synthetic green result.

Any exception to this policy needs an owner, reason, expiry date, rollback,
and repository-local decision record.

## Adoption inventory

This repository is the policy source, not an automatic GitHub enforcement
mechanism. The live adoption baseline is:

| Repository | Protected branches | Repository-local adoption |
| --- | --- | --- |
| Recovr | `dev`, `main` | `AGENTS.md`, `docs/OPERATIONS.md`, and the hosted PR gate |
| Fork | `dev`, `main` | `AGENTS.md`, governance scripts, and CI runbooks |
| BoltScope | `dev`, `main` | `AGENTS.md` and development verification documentation |
| synapselabs_web | `main` | `README.md` CI contract |
| `.github` | `main` | This policy and `CONTRIBUTING.md` |

All listed branches require pull requests and block force pushes and deletion.
Required checks are configured per repository. The organization default
workflow token is read-only, merged branches are automatically deleted, and
artifact and log retention is 14 days. Review this inventory whenever a
repository is created, renamed, archived, or changes its integration branch.
