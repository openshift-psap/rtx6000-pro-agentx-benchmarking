# What happens during a run

The commands for installation and first use are in the [README quickstart](../README.md). This page explains what each stage does and what to inspect when it finishes.

## Before launch

Start the model server on the GPUs being tested using your platform's serving workflow. Keep the deployment ready for the entire sweep. From the runner, confirm that `TARGET_URL` plus `TARGET_PATH` returns the model named by `MODEL_ID`.

Choose one topology per invocation. `TP_SIZE` is GPUs per replica; `REPLICAS` is the number of replicas. Keep both identical to the live deployment. Use a unique `RUN_ID` and a persistent `OUTPUT_ROOT` for each invocation. Edit the matrix file to define its serial case order and concurrency points.

The included profile replays the date-pinned Weka AgentX corpus, uses a 30-minute measurement period, and pins seed `20260707`. Concurrency in the matrix means simultaneously live AgentX session trees, including their subagents. See the [AIPerf AgentX guide](https://github.com/ai-dynamo/aiperf/blob/v0.12.0/docs/tutorials/agentx-mvp.md) before changing the corpus or replay settings.

## Per-case execution

For each row, `scripts/run-benchflow-matrix.sh`:

1. Resolves an immutable BenchFlow RunPlan using the pinned deployment and benchmark profiles.
2. Checks that the resolved plan has the AgentX scenario, requested concurrency, and configured run duration.
3. Sets the policy-specific request header: `agentic` sends the AgentX profile header and session ID; `no_default` sends no EPP profile header.
4. Runs `bflow benchmark run`. BenchFlow invokes AIPerf against the configured endpoint and saves its output under that case's `results/` directory.
5. Runs `scripts/validate_aiperf.py` on the exported `profile_export_aiperf.json` and appends the result to `summary.tsv`.

Cases run serially in matrix order. A failed BenchFlow command, missing export, or invalid export stops the matrix at that case. The runner does not retry it or continue to later rows. This preserves the failed case's artifacts and avoids silently duplicating measurements.

## Accepting a case

The validator accepts an export only when all these checks pass:

- `is_complete` is `true` and `was_cancelled` is `false`.
- `metadata.submission_valid` is `true` and `metadata.scenario` is `inferencex-agentx-mvp`.
- Request count is positive, completed count matches it, and both error count and error rate are zero.

This check verifies AIPerf's benchmark output. It does not prove that the serving deployment, EPP, GPU assignment, or Prometheus scrapes matched the intended experiment. Verify those against your platform's live state and telemetry output as well. For NVIDIA/OpenShift, the optional sampler writes scrape status and raw vLLM/DCGM metrics as described in [its guide](../adapters/nvidia/README.md).

## Read the output

Each run directory contains the exact profile and matrix used, run metadata, the runner log, a case event log, and a summary TSV. Each case directory contains the resolved `runplan.json`, BenchFlow logs, AIPerf results, and validation log. Keep the run directory with the tested service configuration and collected telemetry so the result can be understood later.

After the matrix finishes, stop the model service using the platform workflow that started it and verify that the GPU resources have been released.
