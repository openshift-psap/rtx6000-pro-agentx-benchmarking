# Run lifecycle

This guide separates the portable benchmark step from the platform-specific model deployment. Keep one immutable run ID and one fresh output directory per experiment.

## 1. Plan

Choose and record the model ID, runtime image, tensor parallel size, replica count, profile revision, seed, EPP policy, concurrency order, and duration. The sample AgentX profile is 30 minutes with seed `20260707`. Concurrency is the number of live AgentX session trees. Do not compare cases if the profile, image, EPP behavior, or topology changed without recording it.

Edit a copy of `config/run.env.example` and the matrix. The runner accepts one topology per invocation; change `TP_SIZE` and `REPLICAS` for another deployment layout and use a distinct `RUN_ID`/output directory.

## 2. Provision and verify the service

Use your platform's deployment mechanism to create the serving service and router. The endpoint must be reachable from the runner. Before testing, verify:

- all expected replicas are ready and on the intended devices;
- the serving image and vLLM arguments match the run configuration;
- the route returns the intended model and `/metrics` is reachable if telemetry uses it;
- the *live generated* router/EPP configuration matches the requested policy;
- no unrelated workload owns the devices needed by the run.

The benchmark script does not create, patch, or delete Kubernetes objects. That boundary avoids carrying Lenovo namespace names, PVC names, node names, model-cache paths, or device resource keys into a public reusable runner.

## 3. Prepare a durable runner

The process needs `bflow`, Git, Python 3, this repository, and the BenchFlow checkout at the configured commit. For long runs, execute it in a persistent worker or Kubernetes Job with a durable output volume; do not tie the run to a laptop shell. The worker's network must reach both the model endpoint and the AgentX dataset source.

The source Lenovo execution used a pinned BenchFlow runner image, mounted the launcher and profile in a Job, and wrote results to a PVC. Recreate that arrangement with your platform's service account, volume, node placement, and image policy. Do not copy the archived Lenovo Job YAML as a generic manifest; it depends on Lenovo API objects and storage.

## 4. Run serially

```bash
bash scripts/run-benchflow-matrix.sh config/run.env
```

For each matrix row, the script resolves and checks a BenchFlow RunPlan, applies the EPP request header for `agentic`, runs `bflow benchmark run`, locates `profile_export_aiperf.json`, and applies the validity gate. BenchFlow invokes AIPerf. The first failed or invalid case stops the queue and keeps its artifacts; no automatic retry can create a duplicate measurement.

`no_default` only omits the EPP request header. The server must already be provisioned with `scheduler: {}` and its live generated EPP must be verified. An empty input field may be transformed by a controller; never label an observed weighted scheduler as “No default.”

## 5. Validate and collect telemetry

The runner requires complete, uncancelled, submission-valid AgentX output with a positive request count, matching completed count, and zero errors. It does not treat a successful endpoint health check or Job exit as proof of benchmark validity.

The example disables AIPerf server metrics to match the captured run and enables TLS verification for HTTPS endpoints. Collect GPU and server telemetry during each case with the appropriate platform adapter. For the captured NVIDIA/OpenShift setup, the optional sampler is `adapters/nvidia/metrics-sampler.py`; it is separate from AIPerf's result validator. Check scrape coverage, files, errors, and checksums before accepting a case. A different accelerator needs a corresponding adapter and validation rule.

## 6. Finish and archive

After the matrix ends, independently verify every summary row and expected case directory. Scale down the serving service through its owner, wait for all model pods to terminate, and confirm device allocations have returned. Generate SHA-256 checksums over the accepted run tree. Upload only to a new archive prefix using the team's approved identity and no-overwrite behavior; compare object sizes and checksums after transfer. Credentials must not be stored in the run output or repository.
