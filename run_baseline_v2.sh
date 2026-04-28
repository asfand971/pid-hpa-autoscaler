#!/bin/bash
# =============================================================================
# run_baseline_v2.sh
# Runs all 10 HPA control group experiments with proper HPA reset between runs.
#
# Key fix over v1: Forces HPA back to minReplicas=1 and waits for scale-down
# cooldown to expire before each run, ensuring every run starts from an
# identical cold-start state (1 replica, CPU unknown).
#
# Usage:
#   chmod +x run_baseline_v2.sh
#   ./run_baseline_v2.sh http://127.0.0.1:PORT
#
# Keep tunnel open in a separate terminal:
#   minikube service go-plant-service --url
# =============================================================================

set -e

# --- Configuration ---
PROJECT_DIR="/Users/asfand/Uni/lastSem/pid-hpa-autoscaler"
RESULTS_DIR="$PROJECT_DIR/results/baseline_v2"
LOCUST_FILE="$PROJECT_DIR/chaos/locustfile.py"
VENV="$PROJECT_DIR/.venv/bin/activate"
TOTAL_RUNS=10
RUN_TIME="1500s"
LOG_FILE="$RESULTS_DIR/automation.log"

# How long to wait after forcing scale-down before starting the next run.
# HPA default scale-down stabilisation window is 300s (5 minutes).
# We wait 360s (6 minutes) to be safe.
HPA_COOLDOWN=360

# --- Validate tunnel URL argument ---
if [ -z "$1" ]; then
  echo "ERROR: No tunnel URL provided."
  echo "Usage: ./run_baseline_v2.sh http://127.0.0.1:PORT"
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
echo "HPA Baseline v2 Experiment — $(date)" | tee -a "$LOG_FILE"
echo "Host: $HOST_URL" | tee -a "$LOG_FILE"
echo "Total runs: $TOTAL_RUNS" | tee -a "$LOG_FILE"
echo "HPA cooldown between runs: ${HPA_COOLDOWN}s" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"

# --- Preflight check ---
echo "[PREFLIGHT] Checking service at $HOST_URL/work ..." | tee -a "$LOG_FILE"
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HOST_URL/work" || echo "000")
if [ "$RESPONSE" != "200" ]; then
  echo "ERROR: Service returned HTTP $RESPONSE. Check tunnel is open and pod is running." | tee -a "$LOG_FILE"
  exit 1
fi
echo "[PREFLIGHT] Service OK (HTTP 200)" | tee -a "$LOG_FILE"

# --- Helper: wait for exactly 1 pod to be ready ---
wait_for_single_pod() {
  echo "[WAIT] Waiting for exactly 1 pod to be Ready..." | tee -a "$LOG_FILE"
  local attempts=0
  local max_attempts=60

  while [ $attempts -lt $max_attempts ]; do
    READY=$(kubectl get pods --no-headers | grep "go-plant" | grep "1/1" | grep "Running" | wc -l | tr -d ' ')
    TOTAL=$(kubectl get pods --no-headers | grep "go-plant" | grep -v "Terminating" | wc -l | tr -d ' ')

    if [ "$READY" -eq "1" ] && [ "$TOTAL" -eq "1" ]; then
      echo "[WAIT] Single pod is Ready." | tee -a "$LOG_FILE"
      return 0
    fi

    attempts=$((attempts + 1))
    echo "[WAIT] Attempt $attempts/$max_attempts — Ready: $READY, Total: $TOTAL. Waiting 5s..." | tee -a "$LOG_FILE"
    sleep 5
  done

  echo "ERROR: Pod did not reach single-ready state after 5 minutes." | tee -a "$LOG_FILE"
  exit 1
}

# --- Helper: full reset between runs ---
# Forces HPA back to 1 replica, restarts pod, waits for cooldown
full_reset() {
  local run_num=$1
  echo "[RESET] Full reset after run $run_num..." | tee -a "$LOG_FILE"

  # Step 1: Delete and recreate HPA to clear all scaling history
  echo "[RESET] Deleting HPA to clear scaling history..." | tee -a "$LOG_FILE"
  kubectl delete hpa go-plant-hpa --ignore-not-found=true >> "$LOG_FILE" 2>&1

  # Step 2: Force deployment back to 1 replica
  echo "[RESET] Scaling deployment to 1 replica..." | tee -a "$LOG_FILE"
  kubectl scale deployment go-plant --replicas=1 >> "$LOG_FILE" 2>&1

  # Step 3: Restart the pod for clean state (no residual connections/memory)
  echo "[RESET] Restarting pod..." | tee -a "$LOG_FILE"
  kubectl rollout restart deployment/go-plant >> "$LOG_FILE" 2>&1

  # Step 4: Wait for single pod to be ready
  sleep 10
  wait_for_single_pod

  # Step 5: Recreate HPA fresh
  echo "[RESET] Recreating HPA..." | tee -a "$LOG_FILE"
  kubectl apply -f "$PROJECT_DIR/plant/plant-hpa.yaml" >> "$LOG_FILE" 2>&1

  # Step 6: Wait for HPA cooldown window to expire
  # This ensures HPA starts with no scaling history and CPU reading is stable
  echo "[RESET] Waiting ${HPA_COOLDOWN}s for HPA cooldown to expire..." | tee -a "$LOG_FILE"
  for i in $(seq 1 $((HPA_COOLDOWN / 30))); do
    sleep 30
    HPA_STATE=$(kubectl get hpa go-plant-hpa --no-headers 2>/dev/null || echo "not ready")
    echo "[RESET] ${i}/${HPA_COOLDOWN/30}m — HPA: $HPA_STATE" | tee -a "$LOG_FILE"
  done

  # Step 7: Verify HPA shows 1 replica and CPU is being read
  echo "[RESET] Final HPA state:" | tee -a "$LOG_FILE"
  kubectl get hpa go-plant-hpa | tee -a "$LOG_FILE"

  REPLICAS=$(kubectl get hpa go-plant-hpa --no-headers | awk '{print $6}')
  if [ "$REPLICAS" != "1" ]; then
    echo "WARNING: HPA shows $REPLICAS replicas before run $((run_num + 1)). Expected 1." | tee -a "$LOG_FILE"
    echo "Waiting an additional 60s..." | tee -a "$LOG_FILE"
    sleep 60
    kubectl get hpa go-plant-hpa | tee -a "$LOG_FILE"
  fi

  echo "[RESET] Reset complete. Ready for next run." | tee -a "$LOG_FILE"
}

# --- Determine start run (resume support) ---
START_RUN=1
for i in $(seq 1 $TOTAL_RUNS); do
  if [ -f "$RESULTS_DIR/run${i}_stats.csv" ]; then
    echo "[RESUME] run${i}_stats.csv already exists, skipping run $i" | tee -a "$LOG_FILE"
    START_RUN=$((i + 1))
  fi
done

if [ $START_RUN -gt $TOTAL_RUNS ]; then
  echo "All $TOTAL_RUNS runs already completed." | tee -a "$LOG_FILE"
  exit 0
fi

echo "[START] Starting from run $START_RUN" | tee -a "$LOG_FILE"

# --- Main loop ---
for RUN in $(seq $START_RUN $TOTAL_RUNS); do
  echo "" | tee -a "$LOG_FILE"
  echo "=============================================" | tee -a "$LOG_FILE"
  echo "RUN $RUN / $TOTAL_RUNS — $(date)" | tee -a "$LOG_FILE"
  echo "=============================================" | tee -a "$LOG_FILE"

  # Full reset before every run including the first
  full_reset $((RUN - 1))

  # Verify service still reachable
  echo "[PREFLIGHT] Verifying service before run $RUN..." | tee -a "$LOG_FILE"
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HOST_URL/work" || echo "000")
  if [ "$RESPONSE" != "200" ]; then
    echo "ERROR: Service returned HTTP $RESPONSE before run $RUN." | tee -a "$LOG_FILE"
    echo "Check the tunnel is still open, then rerun the script to resume." | tee -a "$LOG_FILE"
    exit 1
  fi
  echo "[PREFLIGHT] Service OK (HTTP 200)" | tee -a "$LOG_FILE"

  # Log HPA state immediately before run starts
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

  # Verify output
  if [ -f "$RESULTS_DIR/run${RUN}_stats.csv" ]; then
    FAIL_RATE=$(python3 -c "
import pandas as pd
df = pd.read_csv('$RESULTS_DIR/run${RUN}_stats.csv')
agg = df[df['Name']=='Aggregated'].iloc[0]
rate = agg['Failure Count']/agg['Request Count']*100
print(f'{rate:.2f}%')
" 2>/dev/null || echo "unknown")
    echo "[VERIFY] run${RUN}_stats.csv exists. Failure rate: $FAIL_RATE" | tee -a "$LOG_FILE"
  else
    echo "WARNING: run${RUN}_stats.csv not found." | tee -a "$LOG_FILE"
  fi

  echo "[DONE] Run $RUN complete." | tee -a "$LOG_FILE"
done

echo "" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"
echo "ALL $TOTAL_RUNS RUNS COMPLETE — $(date)" | tee -a "$LOG_FILE"
echo "Results saved to: $RESULTS_DIR" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"

# Final summary
echo "" | tee -a "$LOG_FILE"
echo "FAILURE RATE SUMMARY:" | tee -a "$LOG_FILE"
python3 -c "
import pandas as pd, numpy as np, glob

files = sorted(glob.glob('$RESULTS_DIR/run*_stats.csv'))
rates = []
for f in files:
    df = pd.read_csv(f)
    agg = df[df['Name']=='Aggregated'].iloc[0]
    rate = agg['Failure Count']/agg['Request Count']*100
    run = f.split('run')[1].split('_')[0]
    rates.append(rate)
    print(f'  Run {run}: {rate:.2f}%')
print(f'  Mean: {np.mean(rates):.2f}%')
print(f'  Std:  {np.std(rates):.2f}%')
" | tee -a "$LOG_FILE"