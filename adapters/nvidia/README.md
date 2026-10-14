# NVIDIA/OpenShift telemetry

Run the sampler from the repository root in a second shell for the duration of the benchmark. It discovers ready serving pods and the NVIDIA DCGM exporter with `oc`, then writes full vLLM and DCGM Prometheus snapshots plus a row for every successful or failed scrape.

## Requirements

- OpenShift CLI [`oc`](https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html) installed and logged into the cluster. Confirm the active account and project before sampling:

  ```bash
  oc whoami
  oc project YOUR_NAMESPACE
  ```

- Read access to the serving and DCGM exporter pods.
- Network access from the machine running the sampler to the pod IPs. A laptop outside the cluster network usually cannot reach pod IPs; use a cluster-connected runner.
- vLLM HTTPS metrics on port `8000`, NVIDIA DCGM exporter metrics on port `9400`, and the CA bundle trusted by the serving endpoint.

The cluster must already expose DCGM exporter metrics. The NVIDIA [GPU telemetry guide](https://docs.nvidia.com/datacenter/cloud-native/gpu-telemetry/latest/) explains the exporter and GPU Operator setup.
The sampler looks for the exporter in namespace `nvidia-gpu-operator` by default. If your cluster uses another namespace, add `--dcgm-namespace YOUR_DCGM_NAMESPACE` to the command.

## Run it

Replace the uppercase values with the values from your cluster. `YOUR_SERVING_POD_LABEL_SELECTOR` is a Kubernetes label selector, such as `app=my-model`; `YOUR_TOTAL_GPUS` is the total GPU count across the selected replicas.

```bash
python3 adapters/nvidia/metrics-sampler.py --interval 30 \
  --namespace YOUR_NAMESPACE \
  --selector 'YOUR_SERVING_POD_LABEL_SELECTOR' \
  --node YOUR_GPU_NODE \
  --replicas YOUR_REPLICA_COUNT \
  --gpu-total YOUR_TOTAL_GPUS \
  --service-fqdn YOUR_SERVICE.YOUR_NAMESPACE.svc \
  --ca-bundle /path/to/cluster-ca.crt \
  --output /path/to/persistent-output/RUN_ID/telemetry
```

Use `--once` instead of `--interval 30` to perform a single scrape before benchmarking. Stop interval mode with `Ctrl+C` after the sweep. The output directory contains `vllm/*.prom`, `dcgm/*.prom`, `scrapes.tsv`, and progress/summary JSON. A scrape error is recorded in `scrapes.tsv`; an empty output directory or missing file is not evidence of zero utilization.

Run `python3 adapters/nvidia/metrics-sampler.py --help` for the full argument list. Start this sampler in the second shell while the benchmark runs, then stop it with `Ctrl+C` after the sweep.
