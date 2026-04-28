#!/bin/bash
# =============================================================================
# run_baseline_v3.sh
# Runs 10 HPA control group experiments with proper cold-start reset.
#
# Key fix over v2: HPA is recreated AFTER the cooldown, not before.
# This prevents the spurious scale-up caused by stale metrics-server cache
# being read by a freshly recreated HPA during the cooldown window.
#
# Reset sequence per run:
#   1. Delete HPA
#   2. Scale deployment to 1 replica
#   3. Restart pod (clean state)
#   4. Wait for single pod ready
#   5. Wait 360s cooldown (metrics-server cache expires, CPU stabilises)
#   6. Recreate HPA fresh (now reads clean 0% CPU)
#   7. Wait 30s for HPA to take first reading
#   8. Verify HPA shows 1 replica before starting Locust
#
# Usage:
#   chmod +x run_baseline_v3.sh
#   ./run_baseline_v3.sh http://127.0.0.1:PORT
#
# Keep tunnel open in a separate terminal:
#   minikube service go-plant-service --url
# =============================================================================

set -e

# --- Configuration ---
PROJECT_DIR="/Users/asfand/Uni/lastSem/pid-hpa-autoscaler"
RESULTS_DIR="$PROJECT_DIR/results/baseline_v3"
LOCUST_FILE="$PROJECT_DIR/chaos/locustfile.py"
VENV="$PROJECT_DIR/.venv/bin/activate"
TOTAL_RUNS=10
RUN_TIME="1500s"
LOG_FILE="$RESULTS_DIR/automation.log"

# Cooldown BEFORE recreating HPA.
# Gives metrics-server time to flush stale pod metrics from previous run.
# 360s = 6 minutes. Metrics-server scrapes every 15s, cache expires after ~60s.
# This is intentionally generous to guarantee clean state.
COOLDOWN_BEFORE_HPA=360

# Wait AFTER recreating HPA before starting Locust.
# Gives HPA time to take its first clean metric reading (15s scrape interval)
# and confirm it's stable at 1 replica.
WAIT_AFTER_HPA=30

# --- Validate tunnel URL argument ---
if [ -z "$1" ]; then
  echo "ERROR: No tunnel URL provided."
  echo "Usage: ./run_baseline_v3.sh http://127.0.0.1:PORT"
  echo ""
  echo "First run this in a separate terminal and keep it open:"
  echo "  minikube service go-plant-service --url"
  exit 1
fi

HOST_URL="$1"

# --- Setup ---
mkdir -p "$RESULTS_DIR"
source "$VENV"

echo "=============================================" | tee -a "$LOG_FILE"
echo "HPA Baseline v3 Experiment — $(date)" | tee -a "$LOG_FILE"
echo "Host: $HOST_URL" | tee -a "$LOG_FILE"
echo "Total runs: $TOTAL_RUNS" | tee -a "$LOG_FILE"
echo "Cooldown before HPA creation: ${COOLDOWN_BEFORE_HPA}s" | tee -a "$LOG_FILE"
echo "Wait after HPA creation: ${WAIT_AFTER_HPA}s" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"

# --- Preflight ---
echo "[PREFLIGHT] Checking service at $HOST_URL/work ..." | tee -a "$LOG_FILE"
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HOST_URL/work" || echo "000")
if [ "$RESPONSE" != "200" ]; then
  echo "ERROR: Service returned HTTP $RESPONSE. Check tunnel is open and pod is running." | tee -a "$LOG_FILE"
  exit 1
fi
echo "[PREFLIGHT] Service OK (HTTP 200)" | tee -a "$LOG_FILE"

# --- Helper: wait for exactly 1 pod ready ---
wait_for_single_pod() {
  echo "[WAIT] Waiting for exactly 1 pod to be Ready..." | tee -a "$LOG_FILE"
  local attempts=0
  local max_attempts=60

  while [ $attempts -lt $max_attempts ]; do
    READY=$(kubectl get pods --no-headers 2>/dev/null | grep "go-plant" | grep "1/1" | grep "Running" | grep -v "Terminating" | wc -l | tr -d ' ')
    TOTAL=$(kubectl get pods --no-headers 2>/dev/null | grep "go-plant" | grep -v "Terminating" | wc -l | tr -d ' ')

    if [ "$READY" -eq "1" ] && [ "$TOTAL" -eq "1" ]; then
      echo "[WAIT] Single pod is Ready." | tee -a "$LOG_FILE"
      return 0
    fi

    attempts=$((attempts + 1))
    echo "[WAIT] Attempt $attempts/$max_attempts — Ready: $READY, Total non-terminating: $TOTAL. Waiting 5s..." | tee -a "$LOG_FILE"
    sleep 5
  done

  echo "ERROR: Pod did not reach single-ready state after 5 minutes." | tee -a "$LOG_FILE"
  exit 1
}

# --- Helper: full reset between runs ---
full_reset() {
  local run_num=$1
  echo "[RESET] Full reset after run $run_num..." | tee -a "$LOG_FILE"

  # Step 1: Delete HPA to clear all scaling history and decisions
  echo "[RESET] Deleting HPA..." | tee -a "$LOG_FILE"
  kubectl delete hpa go-plant-hpa --ignore-not-found=true >> "$LOG_FILE" 2>&1

  # Step 2: Force deployment back to 1 replica immediately
  echo "[RESET] Scaling deployment to 1 replica..." | tee -a "$LOG_FILE"
  kubectl scale deployment go-plant --replicas=1 >> "$LOG_FILE" 2>&1

  # Step 3: Restart the pod for clean connection/memory state
  echo "[RESET] Restarting pod..." | tee -a "$LOG_FILE"
  kubectl rollout restart deployment/go-plant >> "$LOG_FILE" 2>&1

  # Step 4: Wait for single pod to be ready
  sleep 10
  wait_for_single_pod

  # Step 5: Cooldown - wait for metrics-server to flush stale metrics
  # from the previous run's pods. HPA does NOT exist during this window,
  # so there is no risk of spurious scale-up.
  echo "[RESET] Cooldown: waiting ${COOLDOWN_BEFORE_HPA}s for stale metrics to expire..." | tee -a "$LOG_FILE"
  local intervals=$((COOLDOWN_BEFORE_HPA / 30))
  for i in $(seq 1 $intervals); do
    sleep 30
    PODS=$(kubectl get pods --no-headers 2>/dev/null | grep "go-plant" | grep "1/1" | grep "Running" | wc -l | tr -d ' ')
    CPU=$(kubectl top pods 2>/dev/null | grep "go-plant" | awk '{print $2}' | head -1 || echo "unknown")
    echo "[RESET] ${i}/${intervals} — Pods ready: $PODS, CPU: $CPU" | tee -a "$LOG_FILE"
  done

  # Step 6: Now recreate HPA — metrics-server cache is clean,
  # only the idle single pod's metrics exist
  echo "[RESET] Recreating HPA (after stale metrics expired)..." | tee -a "$LOG_FILE"
  kubectl apply -f "$PROJECT_DIR/plant/plant-hpa.yaml" >> "$LOG_FILE" 2>&1

  # Step 7: Wait for HPA to take its first clean reading
  echo "[RESET] Waiting ${WAIT_AFTER_HPA}s for HPA initial metric read..." | tee -a "$LOG_FILE"
  sleep "$WAIT_AFTER_HPA"

  # Step 8: Verify HPA state before starting
  echo "[RESET] Final HPA state:" | tee -a "$LOG_FILE"
  kubectl get hpa go-plant-hpa | tee -a "$LOG_FILE"
  kubectl get pods | tee -a "$LOG_FILE"

  REPLICAS=$(kubectl get hpa go-plant-hpa --no-headers 2>/dev/null | awk '{print $6}' | tr -d ' ')
  if [ "$REPLICAS" != "1" ]; then
    echo "WARNING: HPA shows $REPLICAS replicas before run $((run_num + 1)). Expected 1." | tee -a "$LOG_FILE"
    echo "[RESET] Waiting additional 60s for HPA to settle..." | tee -a "$LOG_FILE"
    sleep 60
    kubectl get hpa go-plant-hpa | tee -a "$LOG_FILE"
    REPLICAS=$(kubectl get hpa go-plant-hpa --no-headers 2>/dev/null | awk '{print $6}' | tr -d ' ')
    if [ "$REPLICAS" != "1" ]; then
      echo "WARNING: HPA still shows $REPLICAS replicas. Proceeding anyway — check results manually." | tee -a "$LOG_FILE"
    fi
  else
    echo "[RESET] HPA confirmed at 1 replica. Clean state achieved." | tee -a "$LOG_FILE"
  fi

  echo "[RESET] Reset complete." | tee -a "$LOG_FILE"
}

# --- Resume support: find which run to start from ---
START_RUN=1
for i in $(seq 1 $TOTAL_RUNS); do
  if [ -f "$RESULTS_DIR/run${i}_stats.csv" ]; then
    echo "[RESUME] run${i}_stats.csv already exists, skipping run $i" | tee -a "$LOG_FILE"
    START_RUN=$((i + 1))
  fi
done

if [ $START_RUN -gt $TOTAL_RUNS ]; then
  echo "All $TOTAL_RUNS runs already completed. Nothing to do." | tee -a "$LOG_FILE"
  exit 0
fi

echo "[START] Starting from run $START_RUN" | tee -a "$LOG_FILE"

# --- Main loop ---
for RUN in $(seq $START_RUN $TOTAL_RUNS); do
  echo "" | tee -a "$LOG_FILE"
  echo "=============================================" | tee -a "$LOG_FILE"
  echo "RUN $RUN / $TOTAL_RUNS — $(date)" | tee -a "$LOG_FILE"
  echo "=============================================" | tee -a "$LOG_FILE"

  # Full reset before every run
  full_reset $((RUN - 1))

  # Verify service still reachable
  echo "[PREFLIGHT] Verifying service before run $RUN..." | tee -a "$LOG_FILE"
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HOST_URL/work" || echo "000")
  if [ "$RESPONSE" != "200" ]; then
    echo "ERROR: Service returned HTTP $RESPONSE before run $RUN." | tee -a "$LOG_FILE"
    echo "Check the tunnel is still open, then rerun the script to resume from run $RUN." | tee -a "$LOG_FILE"
    exit 1
  fi
  echo "[PREFLIGHT] Service OK (HTTP 200)" | tee -a "$LOG_FILE"

  # Log exact state at run start
  echo "[HPA] State at run $RUN start:" | tee -a "$LOG_FILE"
  kubectl get hpa go-plant-hpa | tee -a "$LOG_FILE"
  kubectl get pods | tee -a "$LOG_FILE"

  # Run Locust
  echo "[LOCUST] Starting run $RUN at $(date)..." | tee -a "$LOG_FILE"
  locust -f "$LOCUST_FILE" \
    --host="$HOST_URL" \
    --headless \
    --users 100 \
    --spawn-rate 10 \
    --run-time "$RUN_TIME" \
    --csv="$RESULTS_DIR/run${RUN}" \
    --csv-full-history \
    --html="$RESULTS_DIR/run${RUN}.html" \
    --logfile="$RESULTS_DIR/run${RUN}.log" \
    2>&1 | tee -a "$LOG_FILE"

  echo "[LOCUST] Run $RUN completed at $(date)" | tee -a "$LOG_FILE"

  # Log HPA state after run
  echo "[HPA] State after run $RUN:" | tee -a "$LOG_FILE"
  kubectl get hpa go-plant-hpa | tee -a "$LOG_FILE"
  kubectl get pods | tee -a "$LOG_FILE"

  # Verify output and print failure rate
  if [ -f "$RESULTS_DIR/run${RUN}_stats.csv" ]; then
    FAIL_RATE=$(python3 -c "
import pandas as pd
df = pd.read_csv('$RESULTS_DIR/run${RUN}_stats.csv')
agg = df[df['Name']=='Aggregated'].iloc[0]
rate = agg['Failure Count']/agg['Request Count']*100
print(f'{rate:.2f}%')
" 2>/dev/null || echo "unknown")
    echo "[VERIFY] run${RUN}_stats.csv OK. Aggregate failure rate: $FAIL_RATE" | tee -a "$LOG_FILE"
  else
    echo "WARNING: run${RUN}_stats.csv not found — Locust may have failed." | tee -a "$LOG_FILE"
  fi

  echo "[DONE] Run $RUN complete." | tee -a "$LOG_FILE"

  # Brief pause between runs (reset handles the real wait)
  if [ $RUN -lt $TOTAL_RUNS ]; then
    echo "[PAUSE] 10s before next reset..." | tee -a "$LOG_FILE"
    sleep 10
  fi
done

# --- Final summary ---
echo "" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"
echo "ALL $TOTAL_RUNS RUNS COMPLETE — $(date)" | tee -a "$LOG_FILE"
echo "Results saved to: $RESULTS_DIR" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "FAILURE RATE SUMMARY:" | tee -a "$LOG_FILE"
python3 -c "
import pandas as pd, numpy as np, glob, os

files = sorted(glob.glob('$RESULTS_DIR/run*_stats.csv'))
if not files:
    print('  No completed runs found.')
else:
    rates = []
    for f in files:
        df = pd.read_csv(f)
        agg = df[df['Name']=='Aggregated'].iloc[0]
        rate = agg['Failure Count']/agg['Request Count']*100
        run = os.path.basename(f).replace('run','').replace('_stats.csv','')
        rates.append(rate)
        print(f'  Run {run}: {rate:.2f}%')
    print(f'  --------')
    print(f'  Mean:   {np.mean(rates):.2f}%')
    print(f'  Median: {np.median(rates):.2f}%')
    print(f'  Std:    {np.std(rates):.2f}%')
    print(f'  Min:    {np.min(rates):.2f}%')
    print(f'  Max:    {np.max(rates):.2f}%')
" | tee -a "$LOG_FILE"