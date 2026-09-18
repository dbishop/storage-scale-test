<!--
SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Kubernetes Substrate for the Elbencho Filesystem Sweep

## Purpose

Add `kubectl` as an explicit third execution substrate for the Elbencho
filesystem scale sweep in `storage-tests/fs/nv-elbencho-sweep.sh`.

Kubernetes runs are asynchronous. The executing host validates and reifies the
sweep, starts one Elbencho service Pod per selected node, freezes their Pod IPv4
addresses, uploads the control bundle, and starts one Job for all pending cells.
The original `kubectl` session is not required afterward.

An existing namespace, PersistentVolume (PV), and PersistentVolumeClaim (PVC)
are prerequisites and are never provisioned or deleted. The PVC holds control
state and completed-cell results; active-cell output stays in Pod-local scratch
and moves to the PVC only between measured cells.

One Kubernetes submission is one **whole-pending-sweep attempt**, not one cell.

## Goals and Non-Goals

### Goals

- Require explicit `slurm | ssh | kubectl` selection with no default.
- Preserve sweep behavior, result compatibility, and successful-cell resume.
- Continue after the submitting Teleport session expires.
- Use the upstream image and one Pod-IP-addressed service per eligible node.
- Persist each completed cell before starting the next.
- Add no template engine, `jq`, Python package, or custom controller dependency.
- Give the in-cluster Job no Kubernetes API credentials or RBAC.
- Support asynchronous status, collection, cleanup, and resume.

### Non-goals

- Provisioning cluster, namespace, node, or storage resources.
- Selecting or refreshing Teleport credentials.
- Concurrent Kubernetes filesystem sweeps; overlapping benchmark IO would
  invalidate isolation.
- Supporting other benchmarks in this initial change.
- Persisting active-cell scratch after coordinator-Pod loss.
- Vendoring Elbencho or publishing an Elbencho image.

The namespace is never deleted. Attempt IDs and labels identify resources; a
PVC-wide run lock rejects concurrent sweeps, and a per-attempt lock rejects
duplicate coordinators.

## User-visible Configuration

### Explicit substrate selection

Replace the current implicit selection rule with one required setting:

```bash
export EXECUTION_SUBSTRATE=slurm  # slurm, ssh, or kubectl
```

Unset, empty, and unsupported values fail. `lib/env_base.sh` derives exactly
one of:

```text
SLURM_ENABLED=1
SSH_ENABLED=1
KUBECTL_ENABLED=1
```

Existing Slurm and SSH settings retain their meanings. `SSH_HOST_LIST` no
longer selects the substrate; it is required only when
`EXECUTION_SUBSTRATE=ssh`.

Other entrypoints must reject `kubectl` with a benchmark-specific unsupported
message.

### Kubernetes settings

Add the following settings to `env.sh.template`:

```bash
export KUBECTL_NAMESPACE=
export KUBECTL_PV=
export KUBECTL_PVC=
export KUBECTL_NODE_SELECTOR=
export KUBECTL_ELBENCHO_IMAGE=breuner/elbencho:v3.1-11
```

Their contracts are:

- `KUBECTL_NAMESPACE` is an existing namespace containing the configured PVC.
- `KUBECTL_PV` is the exact PV expected to back the claim.
- `KUBECTL_PVC` is an existing, bound, filesystem-mode claim usable
  concurrently by all worker and coordinator Pods.
- `KUBECTL_NODE_SELECTOR` is a comma-separated list of equality selectors,
  for example `storage-test=true,role=client`. Set-based selector syntax is
  not supported in the first implementation because the same value must be
  converted into the DaemonSet and Job scheduling constraints without a YAML
  parser.
- `KUBECTL_ELBENCHO_IMAGE` is configurable and defaults to
  `breuner/elbencho:v3.1-11`. Validation must confirm the selected image
  contains Elbencho, Bash, tar, and required coreutils; do not assume a custom
  image has the contents of the default image.

### Pod-network prerequisites

Kubernetes mode uses ordinary Pod networking, not Node addresses. The cluster
must provide:

- Cross-node Pod-to-Pod TCP connectivity and Pod IPv4 addresses. IPv6-only
  clusters are initially unsupported.
- Admission, CNI, policy, and service-mesh settings that permit direct
  coordinator-to-worker TCP 1611 within `KUBECTL_NAMESPACE`.

Attempt-owned NetworkPolicies permit coordinator egress and worker ingress.
They support namespaced default-deny policy but cannot override cluster-wide
policy, admission, or mesh behavior, so a cross-node probe remains authoritative.

No Pod IP needs to be reachable from the executing host. Do not create a
Service, NodePort, host port, or `hostNetwork` Pod for Elbencho coordination;
the in-cluster coordinator consumes numeric Pod IPv4 addresses and needs no DNS
for worker discovery.

### Kubernetes mapping of `TEST_DIRS`

The PVC will always be mounted inside Pods at:

```text
/mnt/storage-scale-test
```

In Kubernetes mode, treat every `TEST_DIRS` key as a PVC-relative logical path
and prepend the mount root internally; users never type the container prefix:

```text
Configured TEST_DIRS key       Kubernetes Pod path
/bench/fs1                     /mnt/storage-scale-test/bench/fs1
bench/fs2                      /mnt/storage-scale-test/bench/fs2
```

The mapping must:

- Strip all leading slashes before joining.
- Collapse redundant slash separators.
- Preserve the configured `TEST_DIRS` weights.
- Reject empty results, `.` components, `..` components, NULs, and any mapping
  that could escape the mount root.
- Reject overlap with the reserved orchestration directory.
- Apply only in Kubernetes mode; Slurm and SSH continue using the configured
  path verbatim.

Reserve this PVC-relative tree for orchestration state:

```text
.storage-scale-test/
├── locks/kubernetes-elbencho-sweep/  atomic global run lock
└── runs/<run-id>/
```

Generated workload targets and operator-provided staged-read paths must not
resolve inside that tree. The orchestration tree must not resolve inside a
generated workload target.

## Asynchronous Command Lifecycle

Refactor argument handling into an explicit operation selector before doing
environment-dependent work. Exactly one operation is active:

| Operation | Invocation | Substrates | Creates a new attempt? |
|---|---|---|---|
| Submit | workload flags plus `--nodes` | Slurm, SSH, Kubernetes | Kubernetes only |
| Resume | `--resume <results_dir>` | Slurm, SSH, Kubernetes | Kubernetes only |
| Status | `--status <results_dir>` | Kubernetes | No |
| Collect | `--collect <results_dir>` | Kubernetes | No |
| Delete-only | `--delete-only <path>` | Slurm and SSH initially | No |

`--resume`, `--status`, and `--collect` restore saved configuration instead of
using current `env.sh` values. Status and collection use current `kubectl`
credentials but require the saved cluster, namespace, and PVC. Kubernetes
`--delete-only` fails as unsupported in this initial change.

Parse before side effects. Reject missing values, incompatible/repeated options,
positional arguments, and workload flags with status, collect, or resume. Keep
existing submit validation and state that an attempt covers the pending sweep.

### Submit

The normal invocation remains the submission command:

```bash
./storage-tests/fs/nv-elbencho-sweep.sh [workload flags] --nodes <node_spec>
```

In Kubernetes mode it will:

1. Validate configuration and the workload.
2. Create the local result directory and snapshots.
3. Reify the complete Cartesian product into the local execution ledger.
4. Generate and persist a Kubernetes attempt ID.
5. Create the transfer Pod, atomically acquire the PVC-wide run lock and reserve
   the run directory, then keep the Pod available for the later upload.
6. Create the attempt NetworkPolicies and worker DaemonSet.
7. Wait for one Ready worker on every recorded node; discover and verify each
   worker's Pod IPv4 address.
8. Write the frozen endpoint mapping into the control bundle, upload that
   bundle once through the transfer Pod, and delete the transfer Pod.
9. Create the sweep Job, record all identities locally, and return after the
   API accepts it.

Submission does not wait for the sweep to finish. Its final output must print
the local result directory and the exact `--status` and `--collect` commands
the operator will use later.

If reservation, policy creation, DaemonSet readiness, endpoint discovery, or
upload fails before Job creation, delete only the attempt's resources and PVC
directory, release its verified global lock, and mark it `SUBMISSION_FAILED`.
If Job creation returns an ambiguous error, query its exact name before deciding
whether submission succeeded or rollback is safe.

### Status

Add:

```bash
./storage-tests/fs/nv-elbencho-sweep.sh --status <results_dir>
```

`--status` is mutually exclusive with every other operation and workload flag.
It does not mutate the execution ledger or clean up benchmark resources.

It reports local and remote identities, namespace/PVC, Job and Pod state, active
cell, durable cell counts, last update, terminal outcome, and allowed next
action. It compares current worker Pod UIDs and IPs with the frozen mapping and
flags replacement or endpoint drift.

While the Job container is running, status may use `kubectl exec` to read the
PVC-backed summary. If the container is unavailable or terminal, create a
short-lived, read-only inspector Pod that mounts the PVC, reads the same
summary, and is deleted before status returns. Job conditions determine whether
the attempt is active or terminal; the PVC ledger supplies cell-level detail.
If the two disagree, report both and refuse to claim success.

### Collect

Add:

```bash
./storage-tests/fs/nv-elbencho-sweep.sh --collect <results_dir>
```

`--collect` is mutually exclusive with all other modes. It refuses to collect
an active Job. For a terminal Job it:

1. Creates a temporary collector Pod mounting the existing PVC.
2. Streams the selected remote run directory into a temporary local archive.
3. Validates archive members, then extracts into a temporary staging directory.
4. Validates attempt identity, snapshots, execution definitions, statuses, exit
   codes, and required workload artifacts.
5. Idempotently publishes verified files into the local result directory using
   temporary files and atomic per-file renames.
6. Removes the attempt's Kubernetes resources and remote PVC directory.
7. Records that the attempt was collected.

A failed sweep is collectible. Collection preserves every completed cell and
the failed cell's available evidence. It returns nonzero when the remote sweep
failed, but the local result directory is left ready for `--resume`.

Transfer or verification failure must leave the remote directory, DaemonSet,
Job, and local pre-collection state intact. Publication is journaled and
idempotent: if it is interrupted after individual renames begin, retry verifies
already-published files and completes the merge. Cleanup never begins until the
entire local publication is verified.

### Resume

The existing command remains:

```bash
./storage-tests/fs/nv-elbencho-sweep.sh --resume <results_dir>
```

For Kubernetes, resume is allowed only after the prior terminal attempt has
been collected. This requirement exists because the asynchronous Job updates
the authoritative execution ledger on the PVC, not in the disconnected local
result directory.

Resume will:

1. Reject a still-running or terminal-but-uncollected attempt.
2. Load the collected configuration and execution ledger.
3. Preserve `SUCCESS`, reset stale `RUNNING` to `PENDING`, and include `FAILED`
   and `PENDING` in the next attempt.
4. Run Submit steps 4–9 with a new attempt ID.

The collection-before-resume rule is intentional: until collection, the PVC
ledger is authoritative and the disconnected local ledger cannot safely know
which cells completed. Help and error messages must state the required next
command, not merely reject resume.

The documented state machine is:

```text
submit
  └─ status (repeat while running)
       ├─ remote success → collect → done
       └─ remote failure → collect partial results → resume
                                                   └─ new attempt
```

## Persistent and Local State

### Attempt identity

Generate an eight-character lowercase hexadecimal attempt ID. Resource names
use the prefix:

```text
sst-elb-<attempt-id>
```

Use these stable names:

```text
sst-elb-<id>-workers     DaemonSet
sst-elb-<id>-sweep       Job
sst-elb-<id>-worker-net  worker-ingress NetworkPolicy
sst-elb-<id>-coord-net   coordinator-egress NetworkPolicy
sst-elb-<id>-upload      initial transfer Pod
sst-elb-<id>-status      temporary inspector Pod
sst-elb-<id>-collect     collection Pod
```

Apply the following labels to every created object:

```yaml
app.kubernetes.io/name: storage-scale-test
app.kubernetes.io/instance: sst-elb-<id>
app.kubernetes.io/component: <workers|coordinator|transfer|network-policy>
app.kubernetes.io/managed-by: storage-scale-test
storage-scale-test.nvidia.com/benchmark: elbencho
storage-scale-test.nvidia.com/run: <id>
```

Generate a candidate ID, reject an existing labeled object or PVC run directory,
and retry on collision. Kubernetes creation and atomic PVC-directory creation
remain authoritative if a check/create race occurs.

### Local metadata

Alongside `env_used.yaml`, `env_used.sh`, and `executions/`, store one immutable
metadata directory per attempt plus an atomic pointer to the current attempt.
Record the attempt and resource IDs; API server, namespace, PV, PVC, image,
selector, mapped paths, and frozen endpoints; remote path; timestamps; outcome;
and lifecycle state (`PREPARED`, `SUBMITTED`, `SUBMISSION_FAILED`, or
`COLLECTED`). Keep a human-readable snapshot and the minimal sourceable sidecar
needed by lifecycle commands. Never overwrite prior attempts when resuming.

These executable/resumable files receive the existing trusted-input warnings.

### Remote PVC layout

The transfer Pod atomically creates
`.storage-scale-test/locks/kubernetes-elbencho-sweep/`, records the attempt ID,
cluster, namespace, and timestamp, then atomically creates the run directory.
An existing lock blocks submission and is never stolen. Upload one bundle:

```text
/mnt/storage-scale-test/.storage-scale-test/runs/<id>/
├── control/
│   ├── manifest.tsv
│   ├── env_used.yaml
│   ├── env_used.sh
│   ├── coordinator.sh
│   ├── _platform_functions.sh
│   ├── _elbencho_functions.sh
│   ├── required shared libraries
│   ├── worker-endpoints.tsv
│   └── executions/
│       └── NNNN.sh
├── state/
│   ├── coordinator.lock/       created atomically by the coordinator
│   ├── run.status
│   ├── run-summary.tsv
│   └── executions/
│       ├── NNNN.status
│       └── NNNN.exitcode
└── results/
    ├── executions/
    │   ├── NNNN.log
    │   ├── NNNN.core
    │   ├── NNNN.write.json
    │   ├── NNNN.read.json
    │   ├── NNNN.delete.json
    │   └── NNNN.workload.tsv
    └── normal Elbencho result, CSV, live-CSV, and tree files
```

All Pods mount this PVC, so libraries and execution definitions are uploaded
once, not copied per Pod. Elbencho comes from the image and is never uploaded.

## Kubernetes Resource Design

### Manifest rendering

Add checked-in templates for the transfer, status, and collector Pods, worker
DaemonSet, sweep Job, and two NetworkPolicies. Render only a narrow, validated
set of placeholders:

- Namespace
- Attempt ID and labels
- Image
- PVC name
- Node-selector key/value pairs
- Recorded worker node names
- Coordinator node name
- Remote run directory

Perform rendering in Bash and submit through `kubectl apply -f -`. Do not add a
template engine. Validate every replacement before interpolation so values
cannot change YAML structure or indentation.

### Node discovery

Use `kubectl get nodes` with the configured selector and Kubernetes-supported
JSONPath or custom-column output. Do not require `jq`.

For every candidate node:

1. Require the Node Ready condition to be true.
2. Record its Kubernetes node name.

Sort the names deterministically and require at least the maximum node count
among pending executions. All matching Ready nodes form the worker pool; do not
silently truncate it.

After the DaemonSet is Ready, list its Pods by exact attempt labels. Require one
Pod on every recorded node, a distinct Pod UID, and a Ready condition. Select
one IPv4 address from each Pod's `status.podIPs`, reject missing or duplicate
addresses, and write node name, Pod name, Pod UID, and Pod IPv4 in deterministic
node order to `control/worker-endpoints.tsv`. The Job uses this frozen mapping
and has no Kubernetes API dependency.

### Worker DaemonSet

Create one DaemonSet for the attempt:

- Use `KUBECTL_ELBENCHO_IMAGE`.
- Constrain scheduling to the configured selector.
- Add required node affinity with `matchFields: metadata.name In [...]` for the
  recorded Ready nodes, so the DaemonSet cannot later expand onto an unrecorded
  matching node.
- Run exactly one Pod on every recorded node.
- Use the normal Pod network and `ClusterFirst` DNS policy; do not set
  `hostNetwork` or `hostPort`.
- Declare container port 1611 for clarity; no Service exposes it.
- Mount the configured PVC at `/mnt/storage-scale-test`.
- Run `elbencho --service --foreground` as the main container process.
- Add HTTP readiness and liveness probes for `/status` on port 1611, with a
  startup probe or equivalent delay so liveness cannot kill a slow startup.
- Use the Kubernetes restart policy inherited by DaemonSet Pods to restart a
  failed service container.

A container restart within the same Pod retains its endpoint and needs no host
upload. Pod replacement changes its UID and may change its IP. Status reports
either drift; if the IP changes, the coordinator's endpoint probes fail the
attempt rather than silently changing the worker set. A same-IP replacement
may continue if Elbencho is healthy.

After applying the DaemonSet, verify that Ready Pods correspond one-for-one
with recorded nodes. On timeout, do not create the Job; perform the pre-Job
rollback defined under Submit. The Job repeats a bounded endpoint check.

### Asynchronous sweep Job

Create one Job for all pending executions:

- Use `KUBECTL_ELBENCHO_IMAGE`.
- Override the image entrypoint with Bash and execute the coordinator script
  from the PVC control bundle.
- Mount the PVC at `/mnt/storage-scale-test`.
- Mount an `emptyDir` at a fixed scratch path such as
  `/tmp/storage-scale-test`.
- Use the normal Pod network and `ClusterFirst` DNS policy; do not set
  `hostNetwork` or `hostPort`.
- Set `automountServiceAccountToken: false`.
- Create no ServiceAccount, Role, RoleBinding, or ClusterRole.
- Restrict scheduling to the configured candidate pool.
- Pin the Job Pod to the first recorded candidate node so single-node cells
  preserve the existing direct-execution behavior.
- Set `restartPolicy: Never`.
- Set `backoffLimit: 0` to disable controller retries after a failed Pod.
- Do not set a TTL that deletes the Job or Pod before status and collection.

The Job needs only the PVC, image, worker mapping, and cluster networking, so it
survives Teleport expiry. It has no Kubernetes API authority; probes handle
worker-process failure and collection cleans up. Because Kubernetes can rarely
start a nominally single-run Job twice, the coordinator acquires a PVC lock
before touching state; a second coordinator exits.

### Coordination NetworkPolicies

Create the two policies before their Pods. Match both ends by attempt and
component labels, allow only TCP 1611, and avoid `ipBlock` with ephemeral Pod
addresses. The submit-time probe catches unsupported or eventually consistent
enforcement and stronger administrator controls.

## Sweep Coordinator Behavior

### Startup

The coordinator will:

1. Load the saved run configuration and libraries from `control/`.
2. Validate that the attempt ID and remote paths match its manifest-provided
   values.
3. Atomically acquire `state/coordinator.lock`; fail without changing the
   ledger if another coordinator owns it.
4. Load the fixed node/Pod/IPv4 mapping.
5. Check every expected `IP:1611` endpoint using the Elbencho HTTP status
   protocol.
6. Retry within a fixed deadline and fail before any benchmark if
   the service fleet does not become healthy.
7. Atomically write sweep state `RUNNING` and the initial summary.

Do not reset a `RUNNING` cell inside an attempt: it is evidence that the prior
coordinator may have died. Collection imports that state, and resume resets it
locally before creating a new attempt. The lock records Pod identity and start
time and remains until collection; a new attempt uses a new run directory.

### Execution ordering and worker selection

Iterate execution IDs in existing `NNNN` order and skip `SUCCESS`.

- With `ORDER_NODES`, select the first `N` recorded Pod IPv4 addresses.
- Without `ORDER_NODES`, use the existing randomized-selection semantics to
  choose `N` addresses for each cell.
- A one-node execution runs directly in the coordinator Pod pinned to the first
  recorded worker node, without `--hosts`, preserving current behavior.
- A multi-node execution passes its selected address CSV through
  `ELBENCHO_RUN_HOSTS_CSV`.

Probe the selected endpoints before each multi-node cell. If an endpoint is
gone, do not refresh in place: fail the attempt, collect completed cells, and
resume into a new DaemonSet and mapping. A failure during measured IO fails that
cell normally. Abort the remaining sequence after the first failure.

### Common-runner refactor

Make the common workload runner accept an explicit run context rather than
inferring Slurm or SSH from ambient variables. The context contains:

- Execution ID
- Node count
- Worker endpoint CSV
- Container-mapped test-directory CSV
- Scratch result directory
- Durable state/result directory
- IO size, threads, depth, and saved workload flags from `NNNN.sh`

Keep reification and workload behavior shared. Move Slurm service checks out of
substrate-neutral phase code and into its adapter. SSH retains its watchdog;
Kubernetes uses DaemonSet probes and precomputed Pod endpoints.

### Per-cell durable commit

For each non-successful execution:

1. Source `control/executions/NNNN.sh`.
2. Translate saved logical `TEST_DIRS` paths to container paths.
3. Atomically write durable `NNNN.status=RUNNING` and update the summary before
   starting measured IO.
4. Create a clean execution-specific directory in `emptyDir`.
5. Direct Elbencho result files, logs, completion JSON/TSV, treefiles, and core
   dumps exclusively to scratch.
6. Run the existing workload phases and cleanup rules against the mapped PVC
   benchmark targets.
7. Wait for all benchmark activity and cleanup activity to finish.
8. Copy each existing scratch artifact to a temporary file under the durable
   remote results tree.
9. Atomically rename every temporary artifact into its final name.
10. Persist the execution exit code.
11. Write `NNNN.status=SUCCESS` or `FAILED` last.
12. Atomically update the summary before beginning another cell.

No result-artifact copy to the PVC may run concurrently with an Elbencho phase.
The small pre-cell status write and post-cell durable commit are explicit
boundaries outside measured benchmark activity.

If a benchmark phase fails, preserve its original return code, run the existing
best-effort workload cleanup, durably publish available evidence, mark the cell
failed, and stop the sweep.

If the coordinator Pod disappears during a cell, only scratch for that cell is
lost. The durable state remains `RUNNING`; collection preserves it and a later
resume resets it to `PENDING`.

### Sweep termination

On normal completion, write durable sweep status `SUCCESS`. On a controlled
cell failure, write `FAILED` with the failed execution ID and original return
code. Signal handlers should publish `FAILED` when possible without claiming
durability for incomplete scratch artifacts.

The worker DaemonSet remains running after either outcome because the Job has
no Kubernetes API authority. Status and documentation must make the required
later collection/cleanup visible.

## Collection and Cleanup

### Collector Pod

Create a temporary collector Pod in the configured namespace using the selected
image and PVC mount. Override the entrypoint with an idle command, wait for the
Pod, and stream a tar archive of exactly the remote attempt directory through
`kubectl exec`. Compression is optional and must use a codec available both in
the image and locally.

Use an explicit tar stream rather than relying on broad `kubectl cp` behavior.
Both mechanisms require `tar` in the container, so validate this image
capability before submission.

Write the stream to a temporary archive adjacent to the result directory.
Before extraction, inspect its member paths and types; reject absolute paths,
`..` traversal, links, devices, unexpected run IDs, and anything outside the
expected layout. Extract only after validation into a new staging directory.

### Verification and publication

Before publishing any file, verify:

- Attempt identity and namespace/PVC metadata.
- Saved configuration snapshots.
- Every expected `NNNN.sh` definition.
- Exactly one valid status value per execution.
- Numeric exit codes for terminal executions.
- All workload-specific artifacts required for each `SUCCESS` cell.
- Result filenames and paths are contained by the intended output directory.

After verification, write a collection journal, then merge remote results and
statuses using temporary files and atomic per-file renames. For an existing
destination, require identical content or preserve it as a conflict and stop.
Preserve submission logs and append collection metadata. Mark publication
complete only after a second full verification of the local result tree.

### Cleanup ordering

Only after successful local publication:

1. Delete `sst-elb-<id>-workers` and wait for its Pods to terminate.
2. Delete `sst-elb-<id>-sweep` and its Pod.
3. Delete any remaining object with the exact attempt label, excluding the
   active collector.
4. Through the collector, delete only
   `.storage-scale-test/runs/<id>` after revalidating the exact normalized path.
5. Remove the global run lock only after verifying that its owner is `<id>`.
6. Delete the collector Pod.
7. Mark the local attempt `COLLECTED` and record its terminal sweep outcome.
8. Release any remaining local dispatch ownership state.

Cleanup is retryable. Persist each completed step so a later `--collect` can
finish cleanup without retransferring or republishing identical results.

Never delete the configured namespace, PV, PVC, storage class, unrelated Pods,
or data retained by `--write-only`.

If any verification, local publication, or cleanup precondition fails, report
the exact retained Kubernetes resources and remote directory. Do not remove
the only durable copy of the results.

## Validation Changes

Extend `validate_env.sh` for Kubernetes without changing the assumption that
plain `kubectl` already targets the correct cluster.

Validation must check:

- `kubectl` reaches the API; print/save context and server, and require later
  lifecycle commands to match the saved server.
- The namespace exists and `kubectl auth can-i` permits required operations,
  including NetworkPolicy create/delete and Pod list/get/exec/log.
- The PVC is in the configured namespace, is `Bound`, has filesystem volume
  mode, advertises `ReadWriteMany`, and names `KUBECTL_PV` in
  `spec.volumeName`.
- The PV exists, the selector uses supported equality syntax, and enough Ready
  nodes match it.
- No active labeled attempt exists in the namespace or reserved PVC tree.
- A validation Pod starts the image, finds Elbencho/Bash/tar/coreutils, mounts
  the PVC, and atomically creates/removes a unique probe under the reserved root.
- Mapped benchmark paths are writable and do not overlap orchestration state.
- A temporary pinned worker DaemonSet receives distinct Pod IPv4 addresses, and
  a coordinator Pod reaches every worker's Elbencho `/status` endpoint on TCP
  1611, including across nodes. Apply the attempt-style NetworkPolicies so the
  probe exercises the actual policy path.

Validation must remove only its own labeled probe resources and files.

Treat `kubectl auth can-i` as an early diagnostic, not proof that admission,
quota, policy, scheduling, image pull, networking, or storage mount will
succeed. Runtime probes remain mandatory and errors must identify the failed
resource and command.

## Implementation Sequence

1. Add explicit substrate selection in `lib/env_base.sh`, `env.sh.template`,
   `validate_env.sh`, and every entrypoint without changing Slurm/SSH behavior.
2. Refactor `nv-elbencho-sweep.sh` into submit, resume, status, collect, and
   delete-only operations before any side effects.
3. Give `lib/_elbencho_functions.sh` an explicit cell-run context; keep
   reification/workloads shared and move lifecycle policy into adapters.
4. Add Kubernetes validation, path mapping, rendering, discovery, ownership,
   transfer, Pod-IP networking, NetworkPolicy, and cleanup helpers, primarily in
   `lib/env_functions.sh`.
5. Add the coordinator and manifest templates under
   `storage-tests/fs/kubectl/`; implement upload, DaemonSet readiness, locked
   Job execution, scratch-to-PVC commits, status, collection, and resume.
6. Add regression and acceptance tests, then update `README.md`, requirements,
   design, architecture diagrams, and repository context.

Each phase should land with tests that leave existing Slurm and SSH operation
usable. Every new text file needs the NVIDIA Apache-2.0 header.

## Test Plan

Use shell-behavior tests with a fake `kubectl`, temporary coordinator trees, and
fake Elbencho commands. Cover these contracts without a cluster:

- Substrate/CLI validation, saved-attempt restoration, unsupported modes, path
  mapping/weights, traversal/reserved paths, and resume remapping.
- API/auth, namespace/PV/PVC/image, selector/node/Pod-IP/capacity, active-run and
  ID/global-lock collision, safe rendering/labels, upload-once, rollback, and
  exact cleanup.
- Both status paths, Job/ledger disagreement, collection gates, hostile
  archives, partial results, retryable publication/cleanup, and remote retention.
- Cartesian order, worker selection, one-node versus `--hosts`, every workload,
  first-failure/exit-code handling, scratch/commit boundaries, loss/resume, and
  duplicate-coordinator exclusion. Cover same-Pod container restart, same-IP
  replacement, and changed-IP replacement separately.
- Manifest invariants: names, exact worker pool, image/PVC, ordinary Pod
  networking, policy selectors, probes, scratch, disabled API token, no retry,
  and no namespace/storage/RBAC creation.

On a representative multi-node cluster, accept the feature only after proving:

- The chosen image and shared PVC work on every selected architecture/node;
  logical paths map correctly; and one- and multi-node cells reach one service
  per Pod IPv4 on port 1611 without host networking or a Service. Repeat under
  a namespaced default-deny policy to verify the attempt allow rules.
- Teleport-session expiry and reauthentication work; prior cells survive
  coordinator loss; failed attempts collect/resume without rerunning successes.
- Result publication occurs only between cells, collected output remains
  analyzer-compatible, cleanup removes only owned state, and the
  namespace/PV/PVC/write-only datasets survive.

Finally run the complete repository check suite with:

```bash
./utils/run_ci_checks.sh
```

## Documentation Requirements

Document substrate selection, prerequisites, automatic `TEST_DIRS` prefixing,
the asynchronous lifecycle, Teleport reauthentication, durability, unsupported
concurrency/delete-only, the credential-free Job, required collection/cleanup,
the external image, and Pod-network requirements. Explain the frozen mapping
and the effects of container restart and same- or changed-IP Pod replacement.

Errors for terminal-but-uncollected resume must explain that collection imports
the authoritative PVC ledger and partial results before a new attempt can be
constructed. Submission output must print copy-pasteable status and collection
commands.

Include the asynchronous lifecycle and the separation among the external
launcher, sweep Job, worker DaemonSet, Pod-IP mapping, NetworkPolicies, PVC
control/results area, and filesystem targets in the architecture diagrams.

## Validated External Assumptions

Revalidate these version-sensitive facts during implementation. At review time,
`breuner/elbencho:v3.1-11` had Linux amd64/arm64 manifests plus Elbencho, Bash,
tar, and coreutils. Elbencho's Kubernetes example passes worker Pod IPs to an
in-cluster coordinator. Kubernetes documents direct Pod networking,
NetworkPolicy segmentation, ephemeral Pods, DaemonSet placement, rare duplicate
Job starts, token-mount opt-out, and tar-based transfer; these drive the design
above.

Primary references: the Kubernetes documentation for
[DaemonSets](https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/),
[Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/),
[the network model](https://kubernetes.io/docs/concepts/services-networking/),
[NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/),
[Pods](https://kubernetes.io/docs/concepts/workloads/pods/),
[service accounts](https://kubernetes.io/docs/concepts/security/service-accounts/),
and [kubectl file transfer](https://kubernetes.io/docs/reference/kubectl/quick-reference/),
plus the upstream [Elbencho Kubernetes example](https://github.com/breuner/elbencho/blob/master/docs/k8s-examples.md)
and [container documentation](https://hub.docker.com/r/breuner/elbencho).
