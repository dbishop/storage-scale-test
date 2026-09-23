# shellcheck shell=bash

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

# Source-only foundations for the asynchronous Kubernetes sweep lifecycle.
# Resource-specific templates and dispatch remain intentionally absent until
# the complete state machine is available.

readonly KUBECTL_SWEEP_MOUNT_ROOT=/mnt/storage-scale-test
readonly KUBECTL_SWEEP_RESERVED_ROOT=.storage-scale-test
readonly KUBECTL_ATTEMPT_SCHEMA_VERSION=1
declare -gA KUBECTL_LOCAL_LOCK_ROOTS=()

kubectl_normalize_logical_path() {
    local value="$1"
    local output_variable="$2"
    if [[ ! "$output_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Error: invalid output variable name" >&2
        return 1
    fi
    if [[ -z "$value" || "$value" == *$'\n'* || "$value" == *$'\r'* \
            || "$value" == *$'\t'* ]]; then
        echo "Error: Kubernetes logical paths must be nonempty single-line values" >&2
        return 1
    fi
    while [[ "$value" == /* ]]; do
        value="${value#/}"
    done
    local -a components=()
    local component
    IFS=/ read -ra components <<< "$value"
    local -a normalized=()
    for component in "${components[@]}"; do
        [[ -z "$component" ]] && continue
        if [[ "$component" == . || "$component" == .. ]]; then
            echo "Error: Kubernetes logical paths may not contain '.' or '..'" >&2
            return 1
        fi
        normalized+=("$component")
    done
    if [[ ${#normalized[@]} -eq 0 ]]; then
        echo "Error: Kubernetes logical paths may not resolve to the mount root" >&2
        return 1
    fi
    local joined
    joined=$(IFS=/; printf '%s' "${normalized[*]}")
    if [[ "$joined" == "$KUBECTL_SWEEP_RESERVED_ROOT" \
            || "$joined" == "$KUBECTL_SWEEP_RESERVED_ROOT/"* ]]; then
        echo "Error: logical path overlaps reserved Kubernetes orchestration state" >&2
        return 1
    fi
    printf -v "$output_variable" '%s' "$joined"
    return 0
}

kubectl_map_logical_path() {
    local logical
    kubectl_normalize_logical_path "$1" logical || return 1
    printf '%s/%s\n' "$KUBECTL_SWEEP_MOUNT_ROOT" "$logical"
}

kubectl_map_test_dirs() {
    local output_name="$1"
    if [[ ! "$output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Error: invalid TEST_DIRS output name" >&2
        return 1
    fi
    local -n output_ref="$output_name"
    output_ref=()
    local source_path mapped_path
    for source_path in "${!TEST_DIRS[@]}"; do
        mapped_path=$(kubectl_map_logical_path "$source_path") || return 1
        if [[ -v output_ref["$mapped_path"] ]]; then
            echo "Error: multiple TEST_DIRS keys map to $mapped_path" >&2
            return 1
        fi
        output_ref["$mapped_path"]="${TEST_DIRS[$source_path]}"
    done
    return 0
}

kubectl_map_read_from_path() {
    local read_path
    kubectl_normalize_logical_path "$1" read_path || return 1
    local matches=0
    local mapped=""
    local root normalized_root suffix
    for root in "${!TEST_DIRS[@]}"; do
        kubectl_normalize_logical_path "$root" normalized_root || return 1
        if [[ "$read_path" == "$normalized_root" ]]; then
            suffix=""
        elif [[ "$read_path" == "$normalized_root/"* ]]; then
            suffix="/${read_path#"$normalized_root/"}"
        else
            continue
        fi
        matches=$((matches + 1))
        mapped="$KUBECTL_SWEEP_MOUNT_ROOT/$normalized_root$suffix"
    done
    if [[ "$matches" -ne 1 ]]; then
        echo "Error: read-from path must belong to exactly one logical TEST_DIRS root" >&2
        return 1
    fi
    printf '%s\n' "$mapped"
}

kubectl_validate_dns_subdomain() {
    local value="$1"
    [[ -n "$value" && ${#value} -le 253 \
        && "$value" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
    local -a labels=()
    local label
    IFS=. read -ra labels <<< "$value"
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 \
            && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
    return 0
}

kubectl_validate_object_name() {
    kubectl_validate_dns_subdomain "$1"
}

kubectl_validate_namespace_name() {
    local value="$1"
    [[ -n "$value" && ${#value} -le 63 \
        && "$value" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

kubectl_validate_uid() {
    local value="$1"
    [[ -n "$value" && ${#value} -le 128 \
        && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]*$ ]]
}

kubectl_validate_label_name() {
    local value="$1"
    [[ -n "$value" && ${#value} -le 63 \
        && "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?$ ]]
}

kubectl_validate_label_value() {
    local value="$1"
    [[ -z "$value" || ( ${#value} -le 63 \
        && "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9_.-]*[A-Za-z0-9])?$ ) ]]
}

kubectl_validate_label_key() {
    local key="$1"
    local prefix="" name="$key"
    if [[ "$key" == */* ]]; then
        prefix="${key%/*}"
        name="${key##*/}"
        [[ "$prefix" != */* ]] || return 1
        kubectl_validate_dns_subdomain "$prefix" || return 1
    fi
    kubectl_validate_label_name "$name"
}

kubectl_validate_node_selector() {
    local selector="$1"
    [[ -n "$selector" ]] || {
        echo "Error: KUBECTL_NODE_SELECTOR is required" >&2
        return 1
    }
    local -A seen=()
    local -a expressions=()
    local expression key value
    IFS=, read -ra expressions <<< "$selector"
    for expression in "${expressions[@]}"; do
        if [[ "$expression" != *=* || "${expression#*=}" == *=* ]]; then
            echo "Error: unsupported Kubernetes equality selector: $expression" >&2
            return 1
        fi
        key="${expression%%=*}"
        value="${expression#*=}"
        if ! kubectl_validate_label_key "$key" \
                || ! kubectl_validate_label_value "$value"; then
            echo "Error: unsupported Kubernetes equality selector: $expression" >&2
            return 1
        fi
        if [[ -v seen["$key"] ]]; then
            echo "Error: duplicate Kubernetes selector key: $key" >&2
            return 1
        fi
        seen["$key"]=1
    done
    return 0
}

_kubectl_random_hex() {
    local bytes="$1"
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

kubectl_generate_attempt_id() {
    _kubectl_random_hex 4
}

kubectl_generate_ownership_nonce() {
    _kubectl_random_hex 16
}

_kubectl_validate_lifecycle_state() {
    [[ "$1" =~ ^(PREPARED|SUBMITTED|CANCEL_REQUESTED|TERMINAL|COLLECTION_IN_PROGRESS|COLLECTED|SUBMISSION_FAILED)$ ]]
}

kubectl_local_lock_acquire() {
    local kubernetes_dir="$1" output_variable="$2"
    [[ "$output_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    mkdir -p "$kubernetes_dir" || return 1
    local lock_fd
    exec {lock_fd}>"$kubernetes_dir/lifecycle.lock" || return 1
    if ! flock -n "$lock_fd"; then
        eval "exec ${lock_fd}>&-"
        return 1
    fi
    KUBECTL_LOCAL_LOCK_ROOTS["$lock_fd"]="$kubernetes_dir"
    printf -v "$output_variable" '%s' "$lock_fd"
}

kubectl_local_lock_release() {
    local lock_fd="$1"
    [[ "$lock_fd" =~ ^[0-9]+$ && -v KUBECTL_LOCAL_LOCK_ROOTS["$lock_fd"] ]] \
        || return 1
    unset 'KUBECTL_LOCAL_LOCK_ROOTS[$lock_fd]'
    flock -u "$lock_fd" || return 1
    eval "exec ${lock_fd}>&-"
}

_kubectl_require_local_lock() {
    local kubernetes_dir="$1" lock_fd="$2"
    [[ "$lock_fd" =~ ^[0-9]+$ \
        && "${KUBECTL_LOCAL_LOCK_ROOTS[$lock_fd]:-}" == "$kubernetes_dir" ]]
}

kubectl_attempt_create_identity() {
    local kubernetes_dir="$1" lock_fd="$2" attempt_id="$3"
    local ownership_nonce="$4" namespace="$5" namespace_uid="$6"
    local pv="$7" pv_uid="$8" pvc="$9" pvc_uid="${10}"
    _kubectl_require_local_lock "$kubernetes_dir" "$lock_fd" || return 1
    [[ "$attempt_id" =~ ^[0-9a-f]{8}$ ]] || return 1
    [[ "$ownership_nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
    if ! kubectl_validate_namespace_name "$namespace" \
            || ! kubectl_validate_uid "$namespace_uid" \
            || ! kubectl_validate_object_name "$pv" \
            || ! kubectl_validate_uid "$pv_uid" \
            || ! kubectl_validate_object_name "$pvc" \
            || ! kubectl_validate_uid "$pvc_uid"; then
        echo "Error: invalid Kubernetes attempt identity" >&2
        return 1
    fi
    local metadata_dir="$kubernetes_dir/attempts/$attempt_id"
    mkdir -p "$kubernetes_dir/attempts" || return 1
    # The directory is the create-only publication boundary. Never adopt or
    # overwrite an identity left by another invocation or interrupted write.
    mkdir "$metadata_dir" || return 1
    local shell_tmp="$metadata_dir/identity.sh.tmp.${BASHPID:-$$}.$RANDOM"
    local yaml_tmp="$metadata_dir/identity.yaml.tmp.${BASHPID:-$$}.$RANDOM"
    {
        printf '# Trusted storage-scale-test Kubernetes attempt metadata.\n'
        printf 'KUBECTL_ATTEMPT_SCHEMA=%q\n' "$KUBECTL_ATTEMPT_SCHEMA_VERSION"
        printf 'KUBECTL_ATTEMPT_ID=%q\n' "$attempt_id"
        printf 'KUBECTL_OWNERSHIP_NONCE=%q\n' "$ownership_nonce"
        printf 'KUBECTL_NAMESPACE=%q\n' "$namespace"
        printf 'KUBECTL_NAMESPACE_UID=%q\n' "$namespace_uid"
        printf 'KUBECTL_PV=%q\n' "$pv"
        printf 'KUBECTL_PV_UID=%q\n' "$pv_uid"
        printf 'KUBECTL_PVC=%q\n' "$pvc"
        printf 'KUBECTL_PVC_UID=%q\n' "$pvc_uid"
    } > "$shell_tmp" || return 1
    {
        printf 'schema: %s\n' "$KUBECTL_ATTEMPT_SCHEMA_VERSION"
        printf 'attempt_id: "%s"\n' "$attempt_id"
        printf 'ownership_nonce: "%s"\n' "$ownership_nonce"
        printf 'namespace: "%s"\n' "$namespace"
        printf 'namespace_uid: "%s"\n' "$namespace_uid"
        printf 'pv: "%s"\n' "$pv"
        printf 'pv_uid: "%s"\n' "$pv_uid"
        printf 'pvc: "%s"\n' "$pvc"
        printf 'pvc_uid: "%s"\n' "$pvc_uid"
    } > "$yaml_tmp" || return 1
    mv "$shell_tmp" "$metadata_dir/identity.sh" \
        && mv "$yaml_tmp" "$metadata_dir/identity.yaml"
}

kubectl_attempt_write_current() {
    local kubernetes_dir="$1" lock_fd="$2" attempt_id="$3"
    _kubectl_require_local_lock "$kubernetes_dir" "$lock_fd" || return 1
    [[ "$attempt_id" =~ ^[0-9a-f]{8}$ ]] || return 1
    [[ -f "$kubernetes_dir/attempts/$attempt_id/identity.sh" ]] || return 1
    local tmp="$kubernetes_dir/current-attempt.tmp.${BASHPID:-$$}.$RANDOM"
    printf '%s\n' "$attempt_id" > "$tmp" \
        && mv -f "$tmp" "$kubernetes_dir/current-attempt"
}

kubectl_attempt_write_state() {
    local kubernetes_dir="$1" lock_fd="$2" attempt_id="$3" state="$4"
    _kubectl_require_local_lock "$kubernetes_dir" "$lock_fd" || return 1
    _kubectl_validate_lifecycle_state "$state" || return 1
    local metadata_dir="$kubernetes_dir/attempts/$attempt_id"
    [[ -f "$metadata_dir/identity.sh" ]] || return 1
    local tmp="$metadata_dir/state.sh.tmp.${BASHPID:-$$}.$RANDOM"
    printf 'KUBECTL_LIFECYCLE_STATE=%q\n' "$state" > "$tmp" \
        && mv -f "$tmp" "$metadata_dir/state.sh"
}

kubectl_attempt_load_metadata() {
    local metadata_dir="$1"
    local identity_file="$metadata_dir/identity.sh"
    local state_file="$metadata_dir/state.sh"
    [[ -f "$identity_file" && ! -L "$identity_file" \
        && -f "$state_file" && ! -L "$state_file" ]] || return 1
    unset KUBECTL_ATTEMPT_SCHEMA KUBECTL_ATTEMPT_ID KUBECTL_OWNERSHIP_NONCE
    unset KUBECTL_LIFECYCLE_STATE KUBECTL_NAMESPACE KUBECTL_NAMESPACE_UID
    unset KUBECTL_PV KUBECTL_PV_UID KUBECTL_PVC KUBECTL_PVC_UID
    # shellcheck disable=SC1090  # Trusted, result-directory-local identity.
    source "$identity_file" || return 1
    # shellcheck disable=SC1090  # Trusted, result-directory-local state.
    source "$state_file" || return 1
    [[ "${KUBECTL_ATTEMPT_SCHEMA:-}" == "$KUBECTL_ATTEMPT_SCHEMA_VERSION" \
        && "${KUBECTL_ATTEMPT_ID:-}" =~ ^[0-9a-f]{8}$ \
        && "${KUBECTL_OWNERSHIP_NONCE:-}" =~ ^[0-9a-f]{32}$ ]] || return 1
    kubectl_validate_namespace_name "${KUBECTL_NAMESPACE:-}" \
        && kubectl_validate_uid "${KUBECTL_NAMESPACE_UID:-}" \
        && kubectl_validate_object_name "${KUBECTL_PV:-}" \
        && kubectl_validate_uid "${KUBECTL_PV_UID:-}" \
        && kubectl_validate_object_name "${KUBECTL_PVC:-}" \
        && kubectl_validate_uid "${KUBECTL_PVC_UID:-}" \
        && _kubectl_validate_lifecycle_state "${KUBECTL_LIFECYCLE_STATE:-}"
}

kubectl_emit_submission_identity() {
    local results_dir="$1" attempt_id="$2"
    [[ -n "$results_dir" && ! "$results_dir" =~ [[:cntrl:]] \
        && "$attempt_id" =~ ^[0-9a-f]{8}$ ]] || return 1
    printf 'STORAGE_SCALE_TEST_RESULTS_DIR=%s\n' "$results_dir"
    printf 'STORAGE_SCALE_TEST_ATTEMPT_ID=%s\n' "$attempt_id"
}

kubectl_emit_state() {
    local state="$1"
    [[ "$state" =~ ^(PREPARED|SUBMITTED|RUNNING|SUCCESS|FAILED|CANCELLED|SUBMISSION_FAILED|COLLECTED)$ ]] \
        || return 1
    printf 'STORAGE_SCALE_TEST_KUBECTL_STATE=%s\n' "$state"
}

_kubectl_validate_placeholder() {
    local token="$1" value="$2"
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* \
        && "$value" != *$'\t'* ]] || return 1
    case "$token" in
        NAMESPACE) kubectl_validate_namespace_name "$value" ;;
        PVC_NAME|RESOURCE_NAME|NODE_NAME|COORDINATOR_NODE)
            kubectl_validate_object_name "$value"
            ;;
        ATTEMPT_ID) [[ "$value" =~ ^[0-9a-f]{8}$ ]] ;;
        OWNERSHIP_NONCE) [[ "$value" =~ ^[0-9a-f]{32}$ ]] ;;
        OPERATION_TOKEN)
            [[ -n "$value" && ${#value} -le 63 \
                && "$value" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
            ;;
        IMAGE)
            [[ -n "$value" && ${#value} -le 512 \
                && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]*$ ]]
            ;;
        IMAGE_PULL_POLICY) [[ "$value" =~ ^(Always|IfNotPresent|Never)$ ]] ;;
        RUN_AS_USER|RUN_AS_GROUP) [[ "$value" =~ ^[1-9][0-9]*$ ]] ;;
        COMPONENT)
            [[ "$value" =~ ^(worker|coordinator|controller|probe)$ ]]
            ;;
        SELECTOR_KEY) kubectl_validate_label_key "$value" ;;
        SELECTOR_VALUE) kubectl_validate_label_value "$value" ;;
        REMOTE_RUN_DIRECTORY)
            [[ "$value" =~ ^/mnt/storage-scale-test/\.storage-scale-test/runs/[0-9a-f]{8}(/[A-Za-z0-9._-]+)*$ ]]
            ;;
        *) return 1 ;;
    esac
}

kubectl_render_template() {
    local template="$1"
    shift
    local rendered="$template" assignment token value
    for assignment in "$@"; do
        if [[ "$assignment" != *=* || "${assignment#*=}" == *=* ]]; then
            echo "Error: Kubernetes template replacements require TOKEN=value" >&2
            return 1
        fi
        token="${assignment%%=*}"
        value="${assignment#*=}"
        if ! _kubectl_validate_placeholder "$token" "$value" \
                || [[ "$rendered" != *"@@$token@@"* ]]; then
            echo "Error: unsafe or unknown Kubernetes template replacement" >&2
            return 1
        fi
        rendered="${rendered//@@$token@@/$value}"
    done
    if [[ "$rendered" == *@@* ]]; then
        echo "Error: unresolved Kubernetes template token" >&2
        return 1
    fi
    printf '%s' "$rendered"
}

kubectl_run_bounded() {
    local request_timeout="${KUBECTL_REQUEST_TIMEOUT_SECONDS:-20}"
    local process_timeout="${KUBECTL_PROCESS_TIMEOUT_SECONDS:-30}"
    timeout --foreground --kill-after=5s "${process_timeout}s" \
        kubectl --request-timeout="${request_timeout}s" "$@"
}

kubectl_verify_object_identity() {
    local kind="$1" name="$2" namespace="$3" nonce="$4" run_id="$5"
    local expected_uid="${6:-}"
    [[ "$kind" =~ ^[A-Za-z][A-Za-z0-9.-]*$ \
        && "$nonce" =~ ^[0-9a-f]{32}$ && "$run_id" =~ ^[0-9a-f]{8}$ ]] \
        || return 1
    kubectl_validate_object_name "$name" \
        && kubectl_validate_namespace_name "$namespace" || return 1
    [[ -z "$expected_uid" ]] || kubectl_validate_uid "$expected_uid" \
        || return 1
    local jsonpath='{.kind}{"\t"}{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.metadata.annotations.storage-scale-test\.nvidia\.com/ownership}{"\t"}{.metadata.labels.storage-scale-test\.nvidia\.com/run}'
    local observed
    observed=$(kubectl_run_bounded -n "$namespace" get "$kind" "$name" \
        -o "jsonpath=$jsonpath") || return 1
    local observed_kind observed_name observed_uid observed_nonce observed_run
    IFS=$'\t' read -r observed_kind observed_name observed_uid observed_nonce \
        observed_run <<< "$observed"
    [[ "${observed_kind,,}" == "${kind,,}" && "$observed_name" == "$name" \
        && "$observed_nonce" == "$nonce" \
        && "$observed_run" == "$run_id" ]] || return 1
    kubectl_validate_uid "$observed_uid" || return 1
    [[ -z "$expected_uid" || "$observed_uid" == "$expected_uid" ]] || return 1
    printf '%s\n' "$observed_uid"
}

kubectl_create_owned_object() {
    local output_variable="$1" kind="$2" name="$3" namespace="$4"
    local nonce="$5" run_id="$6" manifest="$7"
    [[ "$output_variable" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    local create_output=""
    if ! create_output=$(printf '%s' "$manifest" \
            | kubectl_run_bounded -n "$namespace" create -f - 2>&1); then
        printf 'Warning: create response was not authoritative: %s\n' \
            "$create_output" >&2
    fi
    local uid
    uid=$(kubectl_verify_object_identity \
        "$kind" "$name" "$namespace" "$nonce" "$run_id") || return 1
    printf -v "$output_variable" '%s' "$uid"
    return 0
}
