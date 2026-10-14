#!/usr/bin/env python3
import argparse
import csv
import datetime
import json
import pathlib
import re
import signal
import subprocess
import time
import urllib.request
import threading

STOP = threading.Event()

def utc():
    return datetime.datetime.now(datetime.timezone.utc)

def stamp():
    return utc().strftime("%Y%m%dT%H%M%S.%fZ")

def atomic_json(path, obj):
    tmp = path.with_suffix(path.suffix + ".part")
    tmp.write_text(json.dumps(obj, indent=2) + "\n")
    tmp.replace(path)

def oc_json(*args):
    p = subprocess.run(["oc", *args], check=True, capture_output=True, text=True, timeout=30)
    return json.loads(p.stdout)

def ready(p):
    s = p.get("status", {})
    cs = s.get("containerStatuses", [])
    return s.get("phase") == "Running" and bool(cs) and all(x.get("ready", False) for x in cs)

def discover(a):
    serving = oc_json("get", "pods", "-n", a.namespace, "-l", a.selector, "-o", "json")["items"]
    serving = [p for p in serving if p.get("spec", {}).get("nodeName") == a.node and ready(p)]
    if len(serving) != a.replicas:
        raise RuntimeError("ready vLLM pods on target node: %d, expected %d" % (len(serving), a.replicas))
    exporters = oc_json("get", "pods", "-n", a.dcgm_namespace, "-l", "app=nvidia-dcgm-exporter", "-o", "json")["items"]
    exporters = [p for p in exporters if p.get("spec", {}).get("nodeName") == a.node and ready(p)]
    if len(exporters) != 1:
        raise RuntimeError("ready DCGM exporters on target node: %d, expected 1" % len(exporters))
    for p in serving:
        if not p.get("status", {}).get("podIP"):
            raise RuntimeError("vLLM pod has no IP: " + p["metadata"]["name"])
    e = exporters[0]
    if not e.get("status", {}).get("podIP"):
        raise RuntimeError("DCGM exporter has no pod IP")
    return serving, e

def retry(fn):
    last = None
    for attempt in range(2):
        try:
            return fn()
        except Exception as e:
            last = e
            if attempt == 0:
                time.sleep(0.5)
    raise RuntimeError(str(last))

def scrape_vllm(a, ip):
    cmd = [
        "curl", "-sSf", "--max-time", "10", "--cacert", a.ca_bundle,
        "--connect-to", "%s:8000:%s:8000" % (a.service_fqdn, ip),
        "https://%s:8000/metrics" % a.service_fqdn,
    ]
    p = subprocess.run(cmd, check=True, capture_output=True, timeout=12)
    body = p.stdout
    if not body.strip() or b"vllm" not in body.lower():
        raise RuntimeError("metrics endpoint returned no vLLM exposition")
    return body

def scrape_dcgm(ip):
    with urllib.request.urlopen("http://%s:9400/metrics" % ip, timeout=10) as r:
        body = r.read()
    if not body.strip():
        raise RuntimeError("DCGM exporter returned empty metrics")
    count = sum(1 for line in body.splitlines() if line.startswith(b"DCGM_FI_DEV_GPU_UTIL{"))
    return body, count

def safe(s):
    return re.sub(r"[\t\r\n]+", " ", str(s))

def append_rows(path, rows):
    new = not path.exists()
    with path.open("a", newline="") as f:
        w = csv.writer(f, delimiter="\t", lineterminator="\n")
        if new:
            w.writerow(["timestamp_utc", "source", "node", "pod", "pod_ip", "status", "bytes", "gpu_util_series", "node_gpu_util_series", "file", "error"])
        w.writerows(rows)

def save_body(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".part")
    tmp.write_bytes(body)
    tmp.replace(path)

def metric_labels(line):
    return {k.decode(): v.decode() for k, v in re.findall(rb"([A-Za-z_][A-Za-z0-9_]*)=\"([^\"]*)\"", line)}

def cycle(a, out, stats):
    t = utc().isoformat(timespec="milliseconds").replace("+00:00", "Z")
    rows = []
    good = True
    try:
        serving, exporter = discover(a)
    except Exception as e:
        stats["samples_failed"] += 1
        stats["samples_total"] += 1
        append_rows(out / "scrapes.tsv", [[t, "discovery", a.node, "-", "-", "error", 0, 0, 0, "-", safe(e)]])
        return False, None
    target_pods = {p["metadata"]["name"] for p in serving}
    for p in sorted(serving, key=lambda x: x["metadata"]["name"]):
        name = p["metadata"]["name"]
        ip = p["status"]["podIP"]
        try:
            body = retry(lambda: scrape_vllm(a, ip))
            path = out / "vllm" / ("%s--%s.prom" % (stamp(), name))
            save_body(path, body)
            rows.append([t, "vllm", a.node, name, ip, "ok", len(body), 0, 0, str(path.relative_to(out)), ""])
            stats["vllm_scrapes_ok"] += 1
        except Exception as e:
            good = False
            rows.append([t, "vllm", a.node, name, ip, "error", 0, 0, 0, "-", safe(e)])
    ename = exporter["metadata"]["name"]
    eip = exporter["status"]["podIP"]
    endpoint = "http://%s:9400/metrics" % eip
    node_gpu_count = 0
    target_gpu_count = 0
    try:
        body, node_gpu_count = retry(lambda: scrape_dcgm(eip))
        path = out / "dcgm" / ("%s--%s.prom" % (stamp(), ename))
        save_body(path, body)
        target_gpu_count = sum(1 for line in body.splitlines()
            if line.startswith(b"DCGM_FI_DEV_GPU_UTIL{")
            and metric_labels(line).get("namespace") == a.namespace
            and metric_labels(line).get("pod") in target_pods)
        status = "ok" if target_gpu_count == a.gpu_total else "error"
        error = "" if status == "ok" else ("target-pod GPU_UTIL series %d, expected %d; node-wide series %d" % (target_gpu_count, a.gpu_total, node_gpu_count))
        rows.append([t, "dcgm", a.node, ename, eip, status, len(body), target_gpu_count, node_gpu_count, str(path.relative_to(out)), error])
        if status == "ok":
            stats["dcgm_scrapes_ok"] += 1
        else:
            good = False
    except Exception as e:
        good = False
        rows.append([t, "dcgm", a.node, ename, eip, "error", 0, 0, 0, "-", safe(e)])
    append_rows(out / "scrapes.tsv", rows)
    stats["samples_total"] += 1
    if good:
        stats["samples_ok"] += 1
    else:
        stats["samples_failed"] += 1
    stats["last_sample_utc"] = t
    atomic_json(out / "sampler-progress.json", stats)
    return good, {"timestamp_utc": t, "node": a.node, "vllm_ready_pods": len(serving),
                  "dcgm_pod": ename, "dcgm_pod_ip": eip, "dcgm_endpoint": endpoint,
                  "gpu_util_series": target_gpu_count, "node_gpu_util_series": node_gpu_count,
                  "gpu_total": a.gpu_total, "ok": good}

def parse_args():
    p = argparse.ArgumentParser()
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--once", action="store_true")
    mode.add_argument("--interval", type=float)
    p.add_argument("--namespace", required=True)
    p.add_argument("--selector", required=True)
    p.add_argument("--node", required=True)
    p.add_argument("--replicas", type=int, required=True)
    p.add_argument("--gpu-total", type=int, required=True)
    p.add_argument("--service-fqdn", required=True)
    p.add_argument("--ca-bundle", required=True)
    p.add_argument("--dcgm-namespace", default="nvidia-gpu-operator")
    p.add_argument("--output", required=True)
    return p.parse_args()

def main():
    a = parse_args()
    out = pathlib.Path(a.output)
    (out / "vllm").mkdir(parents=True, exist_ok=True)
    (out / "dcgm").mkdir(parents=True, exist_ok=True)
    if a.once:
        stats = {"samples_ok": 0, "samples_failed": 0, "samples_total": 0,
                 "vllm_scrapes_ok": 0, "dcgm_scrapes_ok": 0}
        ok, detail = cycle(a, out, stats)
        if detail:
            atomic_json(out / "preflight.json", detail)
        else:
            (out / "preflight-failure.txt").write_text("Endpoint discovery failed; see scrapes.tsv\n")
        return 0 if ok else 1
    stats = {"started_at_utc": utc().isoformat(timespec="seconds").replace("+00:00", "Z"),
             "samples_ok": 0, "samples_failed": 0, "samples_total": 0,
             "vllm_scrapes_ok": 0, "dcgm_scrapes_ok": 0}
    atomic_json(out / "sampler-progress.json", stats)
    signal.signal(signal.SIGTERM, lambda *_: STOP.set())
    signal.signal(signal.SIGINT, lambda *_: STOP.set())
    while not STOP.is_set():
        started = time.monotonic()
        cycle(a, out, stats)
        STOP.wait(max(0.0, a.interval - (time.monotonic() - started)))
    stats["stopped_at_utc"] = utc().isoformat(timespec="seconds").replace("+00:00", "Z")
    stats["elapsed_seconds"] = round((utc() - datetime.datetime.fromisoformat(stats["started_at_utc"].replace("Z", "+00:00"))).total_seconds(), 1)
    atomic_json(out / "sampler-summary.json", stats)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
