# PID-HPA Autoscaler — MSc Dissertation 2026

**Empirical Evaluation of Control-Theoretic Autoscaling (PID) for Stability in Microservice Architectures Under Chaotic Conditions**

> **Key result:** PID reduced the aggregate failure rate from 73.39% to 43.98% (−40.07%), reduced failures/s from 99.60 to 34.79 (−65.07%), and delivered 22.94% more successful requests per second than HPA — at the cost of higher queuing latency under saturation.

This repository contains the implementation, experiment automation, result exports, and analysis scripts for the MSc Software Engineering dissertation comparing Kubernetes' native **Horizontal Pod Autoscaler (HPA)** against a custom **application-aware PID autoscaler** under a retry-storm workload.

---

## 1. Project Overview

Cloud-native applications commonly use Kubernetes HPA to scale workloads based on resource metrics such as CPU utilisation. This works well for many normal workload patterns, but can react poorly under chaotic conditions such as retry storms, where failed requests are aggressively retried and artificial demand amplifies the original load.

This project implements a controlled Kubernetes testbed using:

- a CPU-bound Go microservice as the controlled system ("plant");
- Kubernetes HPA as the baseline controller;
- a custom Python PID controller as the experimental controller;
- Prometheus for application and infrastructure telemetry;
- Locust for generating a three-phase retry-storm workload;
- Python analysis scripts for statistical comparison and chart generation.

The final dissertation analysis uses the result folders:

```text
results/baseline_v3/   ← Final HPA control-group results
results/pid/           ← Final PID experimental-group results
```

> ⚠️ Older folders (`results/baseline/`, `results/baseline_v2/`) are calibration/pilot outputs. Do not use them for final analysis.

---

## 2. Research Questions

1. **RQ1:** To what extent does an application-aware PID autoscaler reduce failed requests under retry-storm conditions compared with Kubernetes HPA?
2. **RQ2:** How does PID-based feedback control affect request-level recovery behaviour after a retry-storm event compared with HPA?
3. **RQ3:** What latency and throughput trade-offs arise when prioritising rejection-rate stability through a PID controller over CPU-threshold scaling?

---

## 3. Controller Comparison

### 3.1 HPA Baseline (Control Group)

| Parameter | Value |
|---|---|
| Metric | CPU utilisation |
| Target | 60% average CPU utilisation |
| Min replicas | 1 |
| Max replicas | 10 |
| Scaling target | `go-plant` Deployment |
| API version | `autoscaling/v2` |

> HPA asks: **"Is the pod using too much CPU?"**

### 3.2 PID Experimental Controller

| Parameter | Value |
|---|---|
| Metric | HTTP 503 rejection rate |
| Prometheus signal | `plant_http_requests_rejected_total` |
| Process variable | `rate(plant_http_requests_rejected_total[30s])` |
| Setpoint | 0 rejected requests/s |
| Kp | 0.5 |
| Ki | 0.05 |
| Kd | 0.1 |
| Dead band | 2 rejected requests/s |
| Loop interval | 15 seconds |
| Min replicas | 1 |
| Max replicas | 10 |
| Anti-windup | Bounded integral accumulator |

> PID asks: **"Is the service refusing requests?"**

This makes the PID controller application-aware, whereas HPA is infrastructure-metric-driven. Under retry storms, CPU utilisation is an ambiguous signal — it cannot distinguish legitimate demand from artificial retry amplification. The rejection rate is a direct application-layer overload signal.

---

## 4. Repository Structure

```text
pid-hpa-autoscaler/
├── plant/                  # Go microservice (controlled plant)
├── controller/             # Python PID controller + Prometheus client
├── k8s/                    # Kubernetes manifests, HPA config, services
├── locustfiles/            # Locust retry-storm workload scripts
├── scripts/                # Experiment automation scripts
├── analysis/               # Python scripts for result processing + charts
├── results/
│   ├── baseline_v3/        # ✅ Final HPA results (use this)
│   └── pid/                # ✅ Final PID results (use this)
└── README.md
```

---

## 5. Target Microservice: Go Plant

The Go microservice exposes three endpoints:

| Endpoint | Purpose |
|---|---|
| `/work` | CPU-bound bcrypt endpoint used by Locust |
| `/metrics` | Prometheus metrics scrape endpoint |
| `/health` | Health-check endpoint |

The `/work` endpoint performs bcrypt hashing at cost factor 10, creating a reproducible CPU-bound workload that saturates predictably under load.

**Overload-shedding mechanism:**
- The service tracks active in-flight requests via an atomic counter
- When active requests exceed `maxConcurrent = 50`, the service immediately returns HTTP 503
- Each rejection increments `plant_http_requests_rejected_total`
- This gives the PID controller a direct application-layer overload signal

---

## 6. Retry-Storm Workload

The workload is generated using Locust and follows a three-phase 25-minute profile:

| Phase | Time Range | Target Users | Behaviour |
|---|---|---|---|
| Baseline | 0–300 s | 100 users | Steady-state load establishing equilibrium |
| Chaos / Retry Storm | 300–900 s | 1,000 users | 10× load spike with immediate retries on timeout or 5xx |
| Recovery | 900–1,500 s | 100 users | Load returns to baseline; controller recovery observed |

> The Locust script intentionally performs aggressive retries **without exponential backoff or jitter**. This is deliberate — the experiment is designed to simulate the positive-feedback loop of a retry storm. The 10× increase from 100 to 1,000 simulated users is the chaos stimulus.

Exported Locust result files per run:
- `*_stats.csv` — aggregate statistics
- `*_stats_history.csv` — per-second time-series
- `*_failures.csv` — failure log
- `*_exceptions.csv` — exception log

---

## 7. Final Experimental Results

Final analysis: 10 HPA runs vs 10 PID runs, each 25 minutes, same workload profile.

> These results were obtained from the local Minikube testbed described above and should be interpreted as empirical testbed results rather than production-cluster benchmarks.

### 7.1 Aggregate Result Summary

| Metric | HPA Mean | PID Mean | Relative Change with PID |
|---|---:|---:|---:|
| Failure rate (%) | 73.39 | 43.98 | **−40.07%** |
| Failures/s | 99.60 | 34.79 | **−65.07%** |
| Average response time (ms) | 1,761.96 | 2,998.08 | +70.16% |
| Median response time (ms) | 1,170.00 | 1,600.00 | +36.75% |
| p95 response time (ms) | 6,440.00 | 10,000.00 | +55.28% |
| p99 response time (ms) | 9,240.00 | 10,000.00 | +8.23% |
| Raw requests/s | 134.54 | 78.56 | −41.61% |
| **Effective successful requests/s** | **35.80** | **44.01** | **+22.94%** |

### 7.2 Statistical Analysis

All comparisons evaluated with Mann-Whitney U test (non-parametric, n=10 per group) and Cliff's delta effect size.

| Metric | U statistic | p-value | Cliff's delta | Interpretation |
|---|---:|---:|---:|---|
| Failure rate | 98.0 | 0.000330 | −0.96 | Large, significant |
| Failures/s | 100.0 | 0.000183 | −1.00 | Large, significant |
| Average response time | 0.0 | 0.000183 | +1.00 | Large, significant |
| Median response time | 0.0 | 0.000135 | +1.00 | Large, significant |
| p95 latency | 0.0 | 0.000062 | +1.00 | Large, significant |
| p99 latency | 15.0 | 0.002189 | +0.70 | Large, significant |
| Requests/s | 100.0 | 0.000183 | −1.00 | Large, significant |

### 7.3 Phase-Based Analysis

| Controller | Phase | Mean RPS | Mean failures/s | Mean p50 (ms) | Mean p95 (ms) | Failure rate |
|---|---|---:|---:|---:|---:|---:|
| HPA | Baseline | 34.97 | 23.10 | 2,053 | 8,711 | 57.41% |
| PID | Baseline | 47.86 | 0.52 | 1,618 | 3,036 | 1.13% |
| HPA | Chaos | 267.96 | 233.55 | 1,308 | 5,918 | 83.50% |
| PID | Chaos | 115.81 | 84.60 | 2,712 | 9,565 | 67.26% |
| HPA | Recovery | 50.37 | 3.97 | 1,783 | 4,234 | 2.60% |
| PID | Recovery | 56.16 | 2.10 | 1,417 | 3,068 | 2.02% |

### 7.4 Interpretation

The result should not be interpreted as "PID is universally better." The correct interpretation is:

> The PID controller improved availability and effective useful work under retry-storm conditions, but introduced higher queuing delay because it kept more requests alive near the saturation boundary. HPA's lower apparent latency is partly a survivorship artefact — many requests failed quickly, which reduces observed latency distributions but does not represent successful service delivery. When adjusted for success rate, PID delivered 22.94% more useful work per second.

---

## 8. Request-Level Recovery Proxy

A direct replica-level oscillation index was planned but continuous replica-count telemetry was not exported for both controllers. A request-level recovery proxy is used instead.

The proxy measures the time after the recovery phase begins until failures/s remain below a threshold for a sustained 60-second interval.

| Recovery criterion | HPA mean (s) | PID mean (s) | Difference |
|---|---:|---:|---:|
| failures/s ≤ 1 for 60s | 29.00 | 24.10 | −4.90 |
| failures/s ≤ 5 for 60s | 24.20 | 20.00 | −4.20 |
| failures/s ≤ 10 for 60s | 22.40 | 18.40 | −4.00 |

> This is a limitation acknowledged in the dissertation. The proxy reflects user-facing recovery behaviour, not direct controller-state telemetry.

---

## 9. Requirements

| Component | Version |
|---|---|
| macOS or Linux | — |
| Docker Desktop | Latest |
| Minikube | v1.32+ (Kubernetes 1.29+) |
| kubectl | Matching cluster version |
| Helm | v3.x |
| Go | 1.21+ |
| Python | 3.11+ |
| Locust | 2.x |
| Prometheus / kube-prometheus-stack | Via Helm |

> ⚠️ The HPA manifest uses `autoscaling/v2`, which requires Kubernetes 1.23+. Minikube v1.32+ with the Docker driver is recommended for consistent results.

Python dependencies:

```bash
pip install pandas scipy matplotlib kubernetes requests locust
```

---

## 10. Running the Experiment

### 10.1 Start Minikube

```bash
minikube start --driver=docker --cpus=4 --memory=6144
```

### 10.2 Build and Load the Go Plant Image

```bash
docker build -t go-plant:v1 ./plant
minikube image load go-plant:v1
```

### 10.3 Deploy the Plant and Services

```bash
kubectl apply -f k8s/
```

### 10.4 Install Prometheus Monitoring

```bash
minikube addons enable metrics-server

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack
```

### 10.5 Run HPA Baseline (Control Group)

```bash
kubectl apply -f k8s/hpa.yaml
# Then run the Locust workload per your locustfile
```

### 10.6 Run PID Experiment (Experimental Group)

```bash
# Disable HPA first to avoid two controllers competing
kubectl delete hpa go-plant-hpa

# Start the PID controller
python controller/pid_controller.py

# Then run the same Locust workload
```

> Always delete the HPA before starting the PID controller. Running both simultaneously will cause conflicting scaling decisions.

---

## 11. Analysis Workflow

Use only `results/baseline_v3/` and `results/pid/` for final analysis.

```python
# Typical analysis steps

# 1. Load aggregate stats
stats_df = pd.concat([pd.read_csv(f) for f in glob("results/*/run*_stats.csv")])

# 2. Load time-series history
history_df = pd.concat([pd.read_csv(f) for f in glob("results/*/run*_stats_history.csv")])

# 3. Calculate metrics
# failure_rate = failures / total_requests
# effective_rps = requests_per_s * (1 - failure_rate)

# 4. Statistical testing
from scipy.stats import mannwhitneyu
stat, p = mannwhitneyu(hpa_values, pid_values, alternative='two-sided')

# 5. Cliff's delta (effect size)
# delta = (U / (n1 * n2)) * 2 - 1

# 6. Generate charts: failure rate by run, latency, throughput,
#    mean failure intensity over time, p95 latency over time,
#    request-level recovery proxy box plots
```

---

## 12. Known Limitations

- Testbed uses single-node Minikube rather than a multi-node production cluster
- Replica-count telemetry was not continuously exported for both controller groups — oscillation index and classical settling time cannot be directly computed
- Request-level recovery proxy is used in place of replica-level settling time
- Workload is synthetic and intentionally aggressive (no backoff, no jitter)
- PID gains (`Kp=0.5`, `Ki=0.05`, `Kd=0.1`) were tuned heuristically, not via Ziegler-Nichols or formal system identification
- Single process variable (rejection rate) — a production controller would likely incorporate multiple signals
- Results are specific to CPU-bound bcrypt workloads; generalisation to memory-bound or I/O-bound workloads requires further study

---

## 13. Reproducibility

For full reproducibility, the key artefacts are:

| Artefact | Location |
|---|---|
| Go plant source | `plant/` |
| Python PID controller | `controller/pid_controller.py` |
| HPA Kubernetes manifest | `k8s/hpa.yaml` |
| Locust workload script | `locustfiles/` |
| Final HPA results | `results/baseline_v3/` |
| Final PID results | `results/pid/` |
| Analysis scripts | `analysis/` |
| Generated charts | `analysis/charts/` |

> Local absolute paths in shell scripts may need adjusting before running on another machine.

---

## 14. Academic Context

This repository supports an MSc Software Engineering dissertation at the **University of Greater Manchester** (2026). It is a research artefact demonstrating a practical implementation of feedback control in a Kubernetes environment, not a production-ready autoscaling solution.

The project contributes:
1. An empirical benchmark of PID-based autoscaling in a live Kubernetes cluster under retry-storm conditions — addressing the simulation gap identified in the literature
2. A deployable open-source reference implementation of a PID sidecar autoscaler
3. A replicable experimental protocol (10 × 25-minute three-phase chaos runs, Mann-Whitney U + Cliff's delta evaluation) applicable to future autoscaling research

---

## 15. Author

**Asfand Khan**  
MSc Software Engineering  
University of Greater Manchester  
Supervisor: Mr. Andrew Stephenson

---

## 16. Repository

```
https://github.com/asfand971/pid-hpa-autoscaler
```

---

## 17. Licence

No licence has been specified. This repository is provided as an academic research artefact. If you wish to build on this work, please contact the author.

---