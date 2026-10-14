# NVIDIA/OpenShift telemetry adapter

`metrics-sampler.py` is the NVIDIA-specific sampler copied from a successful run. It discovers ready serving pods and the NVIDIA DCGM exporter through `oc`, then saves full vLLM and DCGM Prometheus exposition snapshots plus scrape status.

It requires `oc`, `curl`, Python 3, permission to read serving/exporter pods, a mounted CA bundle, and the arguments shown by:

```bash
python3 adapters/nvidia/metrics-sampler.py --help
```

The adapter expects the vLLM HTTPS metrics endpoint on port 8000 and NVIDIA DCGM exporter on port 9400. Pass namespace, selectors, node, replica/GPU counts, service DNS, CA bundle and output directory explicitly. These are platform inputs, not Lenovo paths. It is not used by the device-neutral BenchFlow runner automatically; wire and validate it in the cluster-specific runner that owns the serving lifecycle.
