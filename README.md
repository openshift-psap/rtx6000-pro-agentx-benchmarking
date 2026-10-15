# RTX PRO 6000 AgentX benchmarking

This repository reproduces AgentX inference benchmarks against an already-running model service. Configure the endpoint and GPU topology, then run a serial concurrency sweep. The scripts preserve per-case plans and raw results, and reject incomplete or invalid measurements.

## Why this repo uses BenchFlow

[BenchFlow](https://github.com/albertoperdomo2/benchflow/tree/854804914535d1df127d9825eb92fa2056eff71f) is a framework for defining and executing repeatable LLM inference benchmarks. Its versioned profiles describe the workload; its resolver combines a profile with the model, endpoint, and topology to produce a concrete `RunPlan`; and its AIPerf backend turns that plan into an AIPerf run and saves the output. AIPerf generates the load. BenchFlow supplies the profile-based setup and execution path around it.

This project uses BenchFlow because the AgentX workload already has a pinned profile and supported AIPerf integration there. Reusing that path avoids translating the profile into a second, hand-maintained AIPerf command. Pinning BenchFlow and checking the copied profile against its source keeps the workload definition and execution code aligned. The matrix script adds the pieces specific to this sweep: serial case ordering, policy headers, per-case artifacts, and acceptance checks.

This quickstart uses BenchFlow's CLI directly against a model service that is already running. It does not bootstrap BenchFlow's broader OpenShift control plane, create the model deployment, or send results to MLflow.

## Before you start

Have these ready:

- The benchmark environment used **OCP 4.22 + Red Hat OpenShift AI (RHOAI) 3.6-ea1** on the **beta** channel. See the [platform installation notes](docs/platform-setup.md) for setup details. The standalone benchmark runner can also target an existing OpenAI-compatible model service.
- A Linux or macOS runner with Bash, Git, `curl`, and network access to your model endpoint and Hugging Face. Windows users can run the commands from WSL2.
- [`uv`](https://docs.astral.sh/uv/getting-started/installation/) to install the pinned Python and BenchFlow versions.
- A model server already running on the GPUs you want to measure. It must expose an OpenAI-compatible API reachable from the runner, serve the model name you will configure, and accept requests at `/v1/chat/completions`. This quickstart measures that service; use your platform's serving instructions to start it.
- The included profile requires a server context limit of at least 131,072 tokens. It sends streaming chat requests and expects server-reported token counts.
- A persistent runner and writable persistent output directory for a multi-hour sweep. Do not run a long sweep in a laptop terminal or an ephemeral container.

The included AgentX profile uses the public, pinned [Weka coding-agent trace dataset](https://huggingface.co/datasets/semianalysisai/cc-traces-weka-062126). AIPerf downloads and prepares it on the first run; you do not need to copy the dataset. The model tokenizer must also be accessible from the runner. If the model repository is gated, provide `HF_TOKEN` through your runner's secret manager or shell environment; do not put tokens in `config/run.env`. The profile fixes the input corpus; there is no separate dataset-path setting in this quickstart.

## 1. Clone this repository and the pinned BenchFlow source

The runner checks that BenchFlow is at the exact [revision used for this profile](https://github.com/albertoperdomo2/benchflow/tree/854804914535d1df127d9825eb92fa2056eff71f). Keep the two checkouts side by side so the example `BENCHFLOW_REPO=../benchflow` works.

```bash
git clone https://github.com/openshift-psap/rtx6000-pro-agentx-benchmarking.git
cd rtx6000-pro-agentx-benchmarking
git clone https://github.com/albertoperdomo2/benchflow.git ../benchflow
git -C ../benchflow checkout 854804914535d1df127d9825eb92fa2056eff71f
```

## 2. Install the runner tools

Install `uv` using one of its [official installation methods](https://docs.astral.sh/uv/getting-started/installation/):

```bash
# macOS with Homebrew
brew install uv

# Linux or WSL2
curl -LsSf https://astral.sh/uv/install.sh | sh

uv --version
```

Then install Python 3.12 and the pinned BenchFlow checkout with its AIPerf support:

```bash
uv python install 3.12
cd ../benchflow
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -e '.[aiperf]'
source .venv/bin/activate
cd -
bflow --help
cmp profiles/aiperf-agentx-inference.yaml ../benchflow/profiles/benchmark/aiperf-agentx-inference.yaml
```

The `cmp` command should print nothing and exit successfully; it confirms the local profile is identical to the pinned source.

The AIPerf dependency is pinned by this BenchFlow revision. You do not need to install or launch AIPerf separately: the matrix runner calls BenchFlow, and BenchFlow runs AIPerf. The first `bflow` command may take a little longer while Matplotlib builds its font cache.

## 3. Start and confirm the model endpoint

Start the model service on the target GPUs using your platform's serving workflow. Keep it running through the whole sweep. This repository's runner benchmarks an existing service; it does not create or resize the model deployment. There is no single safe deployment command for every model, GPU, and platform. List the deployment profiles in the pinned BenchFlow checkout with:

```bash
bflow profiles list --repo-root ../benchflow --kind deployment
bflow profiles show rhaiis-raw-vllm --repo-root ../benchflow --kind deployment
```

The example profile is [`rhaiis-raw-vllm`](https://github.com/albertoperdomo2/benchflow/blob/854804914535d1df127d9825eb92fa2056eff71f/profiles/deployment/rhaiis/raw-vllm.yaml). For vLLM server options, see the [vLLM OpenAI-compatible server guide](https://docs.vllm.ai/en/latest/serving/openai_compatible_server/).

`TARGET_URL` is the endpoint root, without `/v1/models` or `/v1/chat/completions` appended. Confirm that the endpoint responds from the same machine or container that will run the benchmark:

```bash
curl --fail --silent --show-error https://YOUR_ENDPOINT/v1/models
```

The response must list the model ID you will set as `MODEL_ID`. The runner does not configure an API key, so the endpoint must be reachable without an API-key prompt. For HTTPS, the runner must trust the endpoint's certificate; keep TLS verification enabled unless you intentionally accept that risk.

## 4. Set the workload, topology, and output location

Copy the examples and edit them:

```bash
cp config/run.env.example config/run.env
cp config/matrix-agentx.example.tsv config/my-matrix.tsv
${EDITOR:-vi} config/run.env
${EDITOR:-vi} config/my-matrix.tsv
```

In `config/run.env`, set these values for the already-running service:

| Setting | Set it to |
|---|---|
| `RUN_ID` | A unique name for this run. A run ID can only be used once because existing output is never overwritten. |
| `NAMESPACE` | The namespace used by your BenchFlow/platform setup. |
| `MODEL_ID` | The exact model ID returned by `/v1/models`. |
| `RUNTIME_IMAGE` | The image running the model server; this is recorded in the resolved run plan and run metadata. |
| `DEPLOYMENT_PROFILE` | The `metadata.name` from the BenchFlow deployment profile that describes your platform. List available profiles with `bflow profiles list --kind deployment`; the example uses `rhaiis-raw-vllm`. |
| `BENCHFLOW_REPO` and `BENCHFLOW_COMMIT` | Keep `../benchflow` and the pinned commit unless you intentionally port the matching profile and update its local copy. |
| `BENCHMARK_PROFILE` | Keep `aiperf-agentx-inference` for the included AgentX workload. |
| `EXPECTED_DURATION_SECONDS` | Keep `1800` for the included 30-minute profile. If you change the profile duration, set the same value here. |
| `TARGET_URL` | The base URL reachable from the runner, such as `https://model.example.net`. |
| `TARGET_PATH` | The readiness URL path; use `/v1/models` for an OpenAI-compatible server. |
| `TP_SIZE` | GPUs assigned to each model replica in the service that is already running. The runner records this value; it does not allocate GPUs. |
| `REPLICAS` | Number of replicas already running. The runner records this value; it does not scale the service. |
| `MATRIX_FILE` | `config/my-matrix.tsv`. |
| `OUTPUT_ROOT` | A writable persistent directory. Use an absolute path on a mounted volume when running in a container. |

Leave the remaining example flags unchanged for the first run: `NO_RHOAI_AUTH=true` skips Red Hat OpenShift AI-specific authentication, `NO_MLFLOW=true` keeps outputs in `OUTPUT_ROOT`, `DISABLE_AIPERF_SERVER_METRICS=true` disables AIPerf's own server-metrics polling, and `AIPERF_HTTP_SSL_VERIFY=true` verifies HTTPS certificates. The optional NVIDIA sampler collects vLLM and DCGM metrics separately. Change the server-metrics flag to `false` only if you want AIPerf to poll the endpoint's server metrics as well.

`TP_SIZE` and `REPLICAS` must describe the service that is actually running. For example, a four-replica TP2 layout uses `TP_SIZE=2` and `REPLICAS=4`; an eight-replica TP1 layout uses `TP_SIZE=1` and `REPLICAS=8`. Start a new run with a unique `RUN_ID` for each topology. The matrix TSV has one row per serial measurement: `case_id`, `policy`, and `concurrency`. The example covers Agentic EPP at concurrency 2, 8, 16, 32, 64, 96, and 128. Here, concurrency means simultaneously live AgentX session trees, including spawned subagents. Change the rows to select your concurrency points. To use your own input corpus, create a matching BenchFlow profile and update the validator's AgentX-specific submission checks; changing a data path alone is not supported.

For the included workload, the corpus, 30-minute duration, and seed are set in [`profiles/aiperf-agentx-inference.yaml`](profiles/aiperf-agentx-inference.yaml), copied byte-for-byte from the [pinned BenchFlow profile](https://github.com/albertoperdomo2/benchflow/blob/854804914535d1df127d9825eb92fa2056eff71f/profiles/benchmark/aiperf-agentx-inference.yaml). To use another profile for the same AgentX scenario, set `BENCHMARK_PROFILE` to its name and place a byte-identical profile at `profiles/<name>.yaml`; the runner compares that file with the pinned BenchFlow checkout before running. The included validity checker requires AIPerf's `inferencex-agentx-mvp` scenario and `submission_valid=true`. See the [AIPerf v0.12.0 AgentX guide](https://github.com/ai-dynamo/aiperf/blob/v0.12.0/docs/tutorials/agentx-mvp.md) before changing the workload.

### EPP policies in the matrix

- `agentic` sends `EPP-Profile: agentic` and enables AIPerf's session-ID header. Your live router must define that profile and support session affinity.
- `no_default` sends no EPP profile header. Before using it, configure the server's router as intended and inspect the **live generated** EPP configuration. An input `scheduler: {}` alone does not prove the generated EPP has no plugins.

## 5. Run the matrix

Run this from the repository root on the persistent runner. If this is a new terminal, activate the BenchFlow environment first:

```bash
source ../benchflow/.venv/bin/activate
bash scripts/run-benchflow-matrix.sh config/run.env
```

Cases run one at a time. The runner resolves and saves a BenchFlow RunPlan, executes `bflow benchmark run`, validates the AIPerf export, and stops at the first failed or invalid case. It never retries a case or overwrites an existing run directory. The first case can spend several minutes downloading and preparing the trace corpus, then warms the server before its 30-minute measurement. Let the command finish; interrupting AIPerf makes that case invalid.

## 6. Check the results

The run ID is printed when execution starts. Results are under:

```text
<OUTPUT_ROOT>/<RUN_ID>/
├── profile.yaml
├── matrix.tsv
├── summary.tsv
├── runner.log
├── events.tsv
├── metadata.txt
└── cases/<case_id>/
    ├── runplan.json
    ├── benchflow.log
    ├── resolve.log
    ├── metadata.txt
    ├── validation.log
    └── results/**/profile_export_aiperf.json
```

From the repository root, load the same configuration and inspect the generated run directory:

```bash
set -a
source config/run.env
set +a
RUN_DIR="$OUTPUT_ROOT/$RUN_ID"
cat "$RUN_DIR/summary.tsv"
find "$RUN_DIR/cases" -type f -name profile_export_aiperf.json \
  -exec python3 scripts/validate_aiperf.py {} \;
```

A valid case must be complete, not cancelled, have `metadata.submission_valid=true`, have a positive request count, have matching completed and requested counts, and report zero errors. The validation command exits nonzero if any condition fails. A valid AIPerf export does not by itself prove that platform GPU telemetry was collected.

After the matrix, stop the model service using the same platform workflow that started it, and confirm the GPUs have been released.

## Optional: NVIDIA/OpenShift telemetry

For NVIDIA clusters, this repository includes a sampler for per-pod vLLM metrics and NVIDIA DCGM GPU metrics. It requires the [OpenShift CLI](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html), a logged-in `oc` context, permission to read the serving and DCGM exporter pods, and network access from the sampler to their pod IPs. Check `oc whoami` and `oc project YOUR_NAMESPACE` first. Run the sampler in a second shell while the service is up; provide your cluster-specific values:

```bash
python3 adapters/nvidia/metrics-sampler.py --interval 30 \
  --namespace YOUR_NAMESPACE \
  --selector 'YOUR_SERVING_POD_LABEL_SELECTOR' \
  --node YOUR_GPU_NODE \
  --replicas YOUR_REPLICA_COUNT \
  --gpu-total YOUR_TOTAL_GPUS \
  --service-fqdn YOUR_SERVICE.YOUR_NAMESPACE.svc \
  --ca-bundle /path/to/cluster-ca.crt \
  --output /path/to/OUTPUT_ROOT/RUN_ID/telemetry
```

Stop the sampler with `Ctrl+C` after benchmarking. It writes raw `.prom` snapshots, `scrapes.tsv`, and a sampler summary alongside the AIPerf results. See [`adapters/nvidia/README.md`](adapters/nvidia/README.md) for field meanings and requirements. Other accelerator vendors need their own telemetry collection method.
