#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${1:-${RUN_CONFIG:-$ROOT_DIR/config/run.env}}"
[[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="$ROOT_DIR/$CONFIG_FILE"
[[ -r "$CONFIG_FILE" ]] || { printf 'Config file is not readable: %s\n' "$CONFIG_FILE" >&2; exit 2; }
# Config files are intentionally shell syntax so users can set ordinary variables without a parser dependency.
set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

required=(RUN_ID NAMESPACE MODEL_ID RUNTIME_IMAGE DEPLOYMENT_PROFILE BENCHMARK_PROFILE EXPECTED_DURATION_SECONDS BENCHFLOW_REPO BENCHFLOW_COMMIT TARGET_URL TARGET_PATH TP_SIZE REPLICAS MATRIX_FILE OUTPUT_ROOT)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] || { printf 'Required setting is missing: %s\n' "$name" >&2; exit 2; }
done

repo_path() {
  if [[ "$1" = /* ]]; then printf '%s\n' "$1"; else printf '%s/%s\n' "$ROOT_DIR" "$1"; fi
}

BFLOW_DIR="$(repo_path "$BENCHFLOW_REPO")"
MATRIX_PATH="$(repo_path "$MATRIX_FILE")"
OUTPUT_PATH="$(repo_path "$OUTPUT_ROOT")"
PROFILE_COPY="$ROOT_DIR/profiles/$BENCHMARK_PROFILE.yaml"
PROFILE_SOURCE="$BFLOW_DIR/profiles/benchmark/$BENCHMARK_PROFILE.yaml"
RUN_ROOT="$OUTPUT_PATH/$RUN_ID"

for command in bflow git python3; do command -v "$command" >/dev/null || { printf 'Missing command: %s\n' "$command" >&2; exit 2; }; done
[[ -d "$BFLOW_DIR/.git" ]] || { printf 'BenchFlow checkout not found: %s\n' "$BFLOW_DIR" >&2; exit 2; }
[[ -r "$PROFILE_COPY" && -r "$PROFILE_SOURCE" ]] || { printf 'Profile copy or pinned BenchFlow profile is missing\n' >&2; exit 2; }
[[ -r "$MATRIX_PATH" ]] || { printf 'Matrix is not readable: %s\n' "$MATRIX_PATH" >&2; exit 2; }
ACTUAL_COMMIT="$(git -C "$BFLOW_DIR" rev-parse HEAD)"
[[ "$ACTUAL_COMMIT" = "$BENCHFLOW_COMMIT" ]] || { printf 'BenchFlow commit mismatch: expected %s, found %s\n' "$BENCHFLOW_COMMIT" "$ACTUAL_COMMIT" >&2; exit 2; }
git -C "$BFLOW_DIR" diff --quiet HEAD -- "profiles/benchmark/$BENCHMARK_PROFILE.yaml" || { printf 'Pinned BenchFlow profile has local edits\n' >&2; exit 2; }
cmp -s "$PROFILE_COPY" "$PROFILE_SOURCE" || { printf 'Checked-in profile differs from the pinned BenchFlow profile\n' >&2; exit 2; }
[[ "$TP_SIZE" =~ ^[1-9][0-9]*$ && "$REPLICAS" =~ ^[1-9][0-9]*$ ]] || { printf 'TP_SIZE and REPLICAS must be positive integers\n' >&2; exit 2; }
[[ "$EXPECTED_DURATION_SECONDS" =~ ^[1-9][0-9]*$ ]] || { printf 'EXPECTED_DURATION_SECONDS must be a positive integer\n' >&2; exit 2; }
for flag in "${NO_RHOAI_AUTH:-true}" "${NO_MLFLOW:-true}" "${DISABLE_AIPERF_SERVER_METRICS:-true}" "${AIPERF_HTTP_SSL_VERIFY:-true}"; do
  [[ "$flag" = true || "$flag" = false ]] || { printf 'Boolean settings must be true or false\n' >&2; exit 2; }
done
[[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { printf 'RUN_ID contains unsupported characters\n' >&2; exit 2; }
[[ "$RUN_ID" != . && "$RUN_ID" != .. ]] || { printf 'RUN_ID must name a run, not a relative-directory token\n' >&2; exit 2; }

python3 - "$MATRIX_PATH" <<'PY'
import csv, re, sys
with open(sys.argv[1], newline="") as f:
    rows = list(csv.DictReader(f, delimiter="\t"))
if not rows or list(rows[0]) != ["case_id", "policy", "concurrency"]:
    raise SystemExit("matrix must have case_id, policy, concurrency columns")
ids = set()
for row in rows:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", row["case_id"]):
        raise SystemExit(f"invalid case_id: {row['case_id']!r}")
    if row["case_id"] in ids:
        raise SystemExit(f"duplicate case_id: {row['case_id']}")
    ids.add(row["case_id"])
    if row["policy"] not in {"agentic", "no_default"}:
        raise SystemExit(f"unsupported policy: {row['policy']!r}")
    try:
        if int(row["concurrency"]) < 1:
            raise ValueError
    except ValueError:
        raise SystemExit(f"concurrency must be a positive integer: {row['concurrency']!r}")
PY

[[ ! -e "$RUN_ROOT" ]] || { printf 'Refusing to overwrite existing run directory: %s\n' "$RUN_ROOT" >&2; exit 2; }
mkdir -p "$(dirname -- "$RUN_ROOT")"
mkdir "$RUN_ROOT" || { printf 'Run directory already exists: %s\n' "$RUN_ROOT" >&2; exit 2; }
mkdir "$RUN_ROOT/cases"
cp "$PROFILE_COPY" "$RUN_ROOT/profile.yaml"
cp "$MATRIX_PATH" "$RUN_ROOT/matrix.tsv"
printf 'case_id\tpolicy\tconcurrency\tstatus\trequest_count\tcompleted_request_count\terror_request_count\trequest_error_rate\n' > "$RUN_ROOT/summary.tsv"
printf 'run_id=%s\nmodel=%s\nimage=%s\nbenchflow_commit=%s\nprofile=%s\nduration_seconds=%s\ntp_size=%s\nreplicas=%s\n' \
  "$RUN_ID" "$MODEL_ID" "$RUNTIME_IMAGE" "$ACTUAL_COMMIT" "$BENCHMARK_PROFILE" "$EXPECTED_DURATION_SECONDS" "$TP_SIZE" "$REPLICAS" > "$RUN_ROOT/metadata.txt"
exec > >(tee -a "$RUN_ROOT/runner.log") 2>&1

printf 'Starting serial matrix %s at %s\n' "$RUN_ID" "$(date -u +%FT%TZ)"
while IFS=$'\t' read -r case_id policy concurrency; do
  [[ "$case_id" = case_id || -z "$case_id" ]] && continue
  case_dir="$RUN_ROOT/cases/$case_id"
  mkdir -p "$case_dir/results"
  printf 'case_id=%s\tpolicy=%s\tconcurrency=%s\tstatus=running\n' "$case_id" "$policy" "$concurrency" >> "$RUN_ROOT/events.tsv"
  resolve_args=(experiment resolve --namespace "$NAMESPACE" --name "$RUN_ID-$case_id")
  resolve_args+=(--label run_id="$RUN_ID" --label case_id="$case_id" --label policy="$policy" --label concurrency="$concurrency")
  resolve_args+=(--model "$MODEL_ID" --deployment-profile "$DEPLOYMENT_PROFILE" --benchmark-profile "$BENCHMARK_PROFILE")
  resolve_args+=(--target-url "$TARGET_URL" --target-path "$TARGET_PATH" --runtime-image "$RUNTIME_IMAGE")
  resolve_args+=(--replicas "$REPLICAS" --tp "$TP_SIZE" --concurrency "$concurrency")
  [[ "${NO_RHOAI_AUTH:-true}" = true ]] && resolve_args+=(--no-rhoai-auth)
  resolve_args+=(--format json)
  if ! bflow "${resolve_args[@]}" > "$case_dir/runplan.json" 2> "$case_dir/resolve.log"; then
    printf '%s\t%s\t%s\tresolve_failed\t\t\t\t\n' "$case_id" "$policy" "$concurrency" >> "$RUN_ROOT/summary.tsv"
    printf 'BenchFlow plan resolution failed for %s; see %s\n' "$case_id" "$case_dir/resolve.log"
    exit 1
  fi
  if ! python3 - "$case_dir/runplan.json" "$policy" "$case_id" "$concurrency" <<'PY'
import json, os, sys, tempfile
path, policy, case_id, concurrency = sys.argv[1:]
with open(path) as f:
    plan = json.load(f)
args = plan["benchmark"]["aiperf"]["args"]
if args.get("scenario") != "inferencex-agentx-mvp":
    raise SystemExit("resolved plan is not the AgentX MVP scenario")
if args.get("concurrency") != int(concurrency):
    raise SystemExit("resolved profile concurrency differs from matrix")
expected_duration = int(os.environ["EXPECTED_DURATION_SECONDS"])
if args.get("benchmark_duration") != expected_duration:
    raise SystemExit("resolved profile duration differs from EXPECTED_DURATION_SECONDS")
args["header"] = ["EPP-Profile: agentic"] if policy == "agentic" else []
args["no_server_metrics"] = os.environ.get("DISABLE_AIPERF_SERVER_METRICS", "true") == "true"
env = plan["benchmark"].setdefault("env", {})
env["AIPERF_HTTP_SSL_VERIFY"] = os.environ.get("AIPERF_HTTP_SSL_VERIFY", "true")
if policy == "agentic":
    env["AIPERF_HTTP_X_SESSION_ID_FROM_CORRELATION_ID"] = "1"
else:
    env.pop("AIPERF_HTTP_X_SESSION_ID_FROM_CORRELATION_ID", None)
plan["metadata"]["name"] = case_id
plan["metadata"].setdefault("labels", {})["epp_policy"] = policy
fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".runplan-")
with os.fdopen(fd, "w") as f:
    json.dump(plan, f, indent=2)
    f.write("\n")
os.replace(temporary, path)
PY
  then
    printf '%s\t%s\t%s\trunplan_invalid\t\t\t\t\n' "$case_id" "$policy" "$concurrency" >> "$RUN_ROOT/summary.tsv"
    printf 'Resolved run plan failed validation for %s\n' "$case_id"
    exit 1
  fi
  printf 'case_id=%s\tpolicy=%s\tconcurrency=%s\ttp_size=%s\treplicas=%s\n' \
    "$case_id" "$policy" "$concurrency" "$TP_SIZE" "$REPLICAS" > "$case_dir/metadata.txt"
  bflow_args=(benchmark run --run-plan-file "$case_dir/runplan.json" --target-url "$TARGET_URL" --output-dir "$case_dir/results")
  [[ "${NO_RHOAI_AUTH:-true}" = true ]] && bflow_args+=(--no-rhoai-auth)
  [[ "${NO_MLFLOW:-true}" = true ]] && bflow_args+=(--no-mlflow)
  if ! bflow "${bflow_args[@]}" > "$case_dir/benchflow.log" 2>&1; then
    printf '%s\t%s\t%s\tbenchmark_failed\t\t\t\t\n' "$case_id" "$policy" "$concurrency" >> "$RUN_ROOT/summary.tsv"
    printf 'case_id=%s\tpolicy=%s\tconcurrency=%s\tstatus=benchmark_failed\n' "$case_id" "$policy" "$concurrency" >> "$RUN_ROOT/events.tsv"
    printf 'BenchFlow failed for %s; stopping without retry. Artifacts: %s\n' "$case_id" "$case_dir"
    exit 1
  fi
  export_file="$(find "$case_dir/results" -type f -name profile_export_aiperf.json -print -quit)"
  if [[ -z "$export_file" ]]; then
    printf '%s\t%s\t%s\tbenchmark_invalid\t\t\t\t\n' "$case_id" "$policy" "$concurrency" >> "$RUN_ROOT/summary.tsv"
    printf 'AIPerf profile export missing for %s\n' "$case_id" > "$case_dir/validation.log"
    exit 1
  fi
  if ! counts="$(python3 "$ROOT_DIR/scripts/validate_aiperf.py" "$export_file" --summary-tsv 2> "$case_dir/validation.log")"; then
    printf '%s\t%s\t%s\tbenchmark_invalid\t\t\t\t\n' "$case_id" "$policy" "$concurrency" >> "$RUN_ROOT/summary.tsv"
    cat "$case_dir/validation.log"
    exit 1
  fi
  printf '%s\n' "valid AIPerf export: requests/completed/errors/error_rate=$counts" >> "$case_dir/validation.log"
  IFS=$'\t' read -r request_count completed_count error_count error_rate <<< "$counts"
  printf '%s\t%s\t%s\tcompleted_valid\t%s\t%s\t%s\t%s\n' \
    "$case_id" "$policy" "$concurrency" "$request_count" "$completed_count" "$error_count" "$error_rate" >> "$RUN_ROOT/summary.tsv"
  printf 'case_id=%s\tpolicy=%s\tconcurrency=%s\tstatus=completed_valid\n' "$case_id" "$policy" "$concurrency" >> "$RUN_ROOT/events.tsv"
  printf 'Validated %s\n' "$case_id"
done < "$MATRIX_PATH"
printf 'All matrix cases passed AIPerf validation. Telemetry and serving teardown still require platform-specific checks.\n'
