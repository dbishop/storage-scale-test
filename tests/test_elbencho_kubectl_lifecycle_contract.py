# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Normative state-graph tests for the Kubernetes sweep lifecycle."""

from itertools import product
from pathlib import Path
import shutil
import subprocess

import pytest

_ROOT = Path(__file__).resolve().parent.parent
_FUNCTIONS = _ROOT / "storage-tests/fs/kubectl/_nv-elbencho-kubectl-functions.sh"
_BASH = shutil.which("bash") or "/bin/bash"

_STATES = (
    "PREPARED",
    "SUBMITTED",
    "CANCEL_REQUESTED",
    "TERMINAL",
    "COLLECTION_IN_PROGRESS",
    "COLLECTED",
    "SUBMISSION_FAILED",
)
_LEGAL_TRANSITIONS = {
    ("PREPARED", "SUBMITTED"),
    ("PREPARED", "SUBMISSION_FAILED"),
    ("SUBMITTED", "CANCEL_REQUESTED"),
    ("SUBMITTED", "TERMINAL"),
    ("CANCEL_REQUESTED", "TERMINAL"),
    ("TERMINAL", "COLLECTION_IN_PROGRESS"),
    ("COLLECTION_IN_PROGRESS", "COLLECTED"),
}


@pytest.mark.parametrize("initial", _STATES)
def test_new_attempt_has_exactly_one_legal_initial_state(
    tmp_path: Path, initial: str
) -> None:
    """The implicit new vertex has only the documented edge to PREPARED."""
    state_root = tmp_path / initial.lower()
    result = subprocess.run(
        [
            _BASH,
            "-c",
            (
                f"source {_FUNCTIONS!s}\n"
                "root=$1\n"
                "initial=$2\n"
                'kubectl_local_lock_acquire "$root" fd\n'
                'kubectl_attempt_create_identity "$root" "$fd" 1234abcd '
                "0123456789abcdef0123456789abcdef test-ns namespace-uid "
                "test-pv pv-uid test-pvc pvc-uid\n"
                'kubectl_attempt_write_state "$root" "$fd" 1234abcd "$initial"'
            ),
            "lifecycle-contract",
            str(state_root),
            initial,
        ],
        cwd=_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    assert (result.returncode == 0) is (initial == "PREPARED"), (
        f"unexpected initial lifecycle edge new -> {initial}: "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )


@pytest.mark.parametrize(("previous", "next_state"), list(product(_STATES, repeat=2)))
def test_exact_local_attempt_transition_graph(
    tmp_path: Path, previous: str, next_state: str
) -> None:
    """Every documented local edge succeeds and every other state pair fails."""
    paths = {
        "PREPARED": (),
        "SUBMITTED": ("SUBMITTED",),
        "CANCEL_REQUESTED": ("SUBMITTED", "CANCEL_REQUESTED"),
        "TERMINAL": ("SUBMITTED", "TERMINAL"),
        "COLLECTION_IN_PROGRESS": (
            "SUBMITTED",
            "TERMINAL",
            "COLLECTION_IN_PROGRESS",
        ),
        "COLLECTED": (
            "SUBMITTED",
            "TERMINAL",
            "COLLECTION_IN_PROGRESS",
            "COLLECTED",
        ),
        "SUBMISSION_FAILED": ("SUBMISSION_FAILED",),
    }
    setup_transitions = "\n".join(
        f'kubectl_attempt_transition "$root" "$fd" 1234abcd {state}'
        for state in paths[previous]
    )
    result = subprocess.run(
        [
            _BASH,
            "-c",
            (
                f"source {_FUNCTIONS!s}\n"
                'root="$1"\n'
                'kubectl_local_lock_acquire "$root" fd\n'
                'kubectl_attempt_create_identity "$root" "$fd" 1234abcd '
                "0123456789abcdef0123456789abcdef test-ns namespace-uid "
                "test-pv pv-uid test-pvc pvc-uid\n"
                'kubectl_attempt_write_state "$root" "$fd" 1234abcd PREPARED\n'
                f"{setup_transitions}\n"
                'kubectl_attempt_transition "$root" "$fd" 1234abcd "$2"\n'
                "transition_rc=$?\n"
                'kubectl_attempt_load_metadata "$root/attempts/1234abcd"\n'
                'printf "%s\\t%s\\n" "$transition_rc" '
                '"$KUBECTL_LIFECYCLE_STATE"\n'
                'kubectl_local_lock_release "$fd"\n'
            ),
            "lifecycle-contract",
            str(tmp_path / f"{previous}-{next_state}"),
            next_state,
        ],
        cwd=_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    expected = (previous, next_state) in _LEGAL_TRANSITIONS
    expected_state = next_state if expected else previous
    assert result.returncode == 0
    assert result.stdout.strip() == f"{0 if expected else 1}\t{expected_state}", (
        f"unexpected lifecycle edge result for {previous} -> {next_state}: "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )


@pytest.mark.parametrize("unknown", ("", "RUNNING", "SUCCESS", "FAILED", "UNKNOWN"))
def test_nonlocal_or_unknown_states_are_not_local_transition_vertices(
    unknown: str,
) -> None:
    """PVC-run outcomes and invented states cannot enter the local graph."""
    for known in _STATES:
        for previous, next_state in ((unknown, known), (known, unknown)):
            result = subprocess.run(
                [
                    _BASH,
                    "-c",
                    (
                        f"source {_FUNCTIONS!s}\n"
                        '! kubectl_transition_is_valid "$1" "$2"'
                    ),
                    "lifecycle-contract",
                    previous,
                    next_state,
                ],
                cwd=_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            assert result.returncode == 0, (
                f"unexpected graph vertex {previous!r} -> {next_state!r}: "
                f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
