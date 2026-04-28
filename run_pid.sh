#!/bin/bash
# =============================================================================
# run_pid.sh
# Runs 10 PID controller experimental group runs unattended.
#
# Key differences from run_baseline_v3.sh:
#   - No HPA involved at all
#   - Resets both go-plant pod AND pid-controller pod between runs
#     (resetting pid-controller clears internal PID state: integral, derivative)
#   - No HPA cooldown needed — just wait for both pods to be ready
#   - Results saved to results/pid/
#
# Usage:
#   chmod +x run_pid.sh
#   ./run_pid.sh http://127.0.0.1:PORT
#
# Keep tunnel open in a separate terminal:
#   minikube service go-plant-service --url
# =============================================================================

set -e

# --- Configuration ---
PROJECT_DIR="/Users/asfand/Uni/lastSem/pid-hpa-autoscaler"
RESULTS_DIR="$PROJECT_DIR/results/pid"
LOCUST_FILE="$PROJECT_DIR/chaos/locustfile.py"
VENV="$PROJECT_DIR/.venv/bin/activate"
TOTAL_RUNS=10
RUN_TIME="1500s"
LOG_FILE="$RESULTS_DIR/automation.log"

# Wait after pod restarts before starting Locust.
# Gives PID controller time to connect to Prometheus and take first reading.
SETTLE_TIME=45

# --- Validate tunnel URL ---
if [ -z "$1" ]; then
  echo "ERROR: No tunnel URL provided."
  echo "Usage: ./run_pid.sh http://127.0.0.1:PORT"
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
echo "PID Experimental Group — $(date)" | tee -a "$LOG_FILE"
echo "Host: $HOST_URL" | tee -a "$LOG_FILE"
echo "Total runs: $TOTAL_RUNS" | tee -a "$LOG_FILE"
echo "Settle time after reset: ${SETTLE_TIME}s" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"

# --- Preflight ---
echo "[PREFLIGHT] Checking service at $HOST_URL/work ..." | tee -a "$LOG_FILE"
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HOST_URL/work" || echo "000")
if [ "$RESPONSE" != "200" ]; then
  echo "ERROR: Service returned HTTP $RESPONSE. Check tunnel is open." | tee -a "$LOG_FILE"
  exit 1
fi
echo "[PREFLIGHT] Service OK (HTTP 200)" | tee -a "$LOG_FILE"

# Confirm HPA is not running
HPA_EXISTS=$(kubectl get hpa go-plant-hpa --ignore-not-found 2>/dev/null | wc -l | tr -d ' ')
if [ "$HPA_EXISTS" -gt "1" ]; then
  echo "WARNING: HPA is still running. Deleting it now..." | tee -a "$LOG_FILE"
  kubectl delete hpa go-plant-hpa --ignore-not-found=true
fi
echo "[PREFLIGHT] HPA confirmed absent." | tee -a "$LOG_FILE"

# --- Helper: wait for a single pod of a deployment to be ready ---
wait_for_deployment() {
  local deployment=$1
  local attempts=0
  local max_attempts=60

  echo "[WAIT] Waiting for $deployment to be Ready..." | tee -a "$LOG_FILE"
  while [ $attempts -lt $max_attempts ]; do
    READY=$(kubectl get pods --no-headers 2>/dev/null | grep "$deployment" | grep "1/1" | grep "Running" | grep -v "Terminating" | wc -l | tr -d ' ')
    TOTAL=$(kubectl get pods --no-headers 2>/dev/null | grep "$deployment" | grep -v "Terminating" | wc -l | tr -d ' ')

    if [ "$READY" -ge "1" ] && [ "$TOTAL" -eq "$READY" ]; then
      echo "[WAIT] $deployment is Ready." | tee -a "$LOG_FILE"
      return 0
    fi

    attempts=$((attempts + 1))
    echo "[WAIT] $deployment — Ready: $READY, Total: $TOTAL. Waiting 5s..." | tee -a "$LOG_FILE"
    sleep 5
  done

  echo "ERROR: $deployment did not become ready after 5 minutes." | tee -a "$LOG_FILE"
  exit 1
}

# --- Helper: full reset between runs ---
full_reset() {
  local run_num=$1
  echo "[RESET] Full reset after run $run_num..." | tee -a "$LOG_FILE"

  # Step 1: Restart go-plant pod (clean connection state, zero counters)
  echo "[RESET] Restarting go-plant..." | tee -a "$LOG_FILE"
  kubectl rollout restart deployment/go-plant >> "$LOG_FILE" 2>&1

  # Step 2: Restart pid-controller pod (resets PID integral and derivative state)
  echo "[RESET] Restarting pid-controller (clears PID internal state)..." | tee -a "$LOG_FILE"
  kubectl rollout restart deployment/pid-controller >> "$LOG_FILE" 2>&1

  # Step 3: Wait for both to be ready
  sleep 10
  wait_for_deployment "go-plant"
  wait_for_deployment "pid-controller"

  # Step 4: Wait for PID controller to connect to Prometheus and stabilise
  echo "[RESET] Waiting ${SETTLE_TIME}s for PID controller to stabilise..." | tee -a "$LOG_FILE"
  sleep "$SETTLE_TIME"

  # Step 5: Confirm state
  echo "[RESET] Pod state:" | tee -a "$LOG_FILE"
  kubectl get pods | grep -E "go-plant|pid-controller" | tee -a "$LOG_FILE"

  echo "[RESET] PID controller last log lines:" | tee -a "$LOG_FILE"
  kubectl logs deployment/pid-controller --tail=3 2>/dev/null | tee -a "$LOG_FILE"

  echo "[RESET] Reset complete." | tee -a "$LOG_FILE"
}

# --- Resume support ---
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

  # Full reset before every run
  full_reset $((RUN - 1))

  # Verify service reachable
  echo "[PREFLIGHT] Verifying service before run $RUN..." | tee -a "$LOG_FILE"
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HOST_URL/work" || echo "000")
  if [ "$RESPONSE" != "200" ]; then
    echo "ERROR: Service returned HTTP $RESPONSE before run $RUN." | tee -a "$LOG_FILE"
    echo "Check the tunnel is still open, then rerun the script to resume." | tee -a "$LOG_FILE"
    exit 1
  fi
  echo "[PREFLIGHT] Service OK (HTTP 200)" | tee -a "$LOG_FILE"

  # Log state at run start
  echo "[STATE] At run $RUN start:" | tee -a "$LOG_FILE"
  kubectl get pods | grep -E "go-plant|pid-controller" | tee -a "$LOG_FILE"

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

  # Log pod state after run
  echo "[STATE] After run $RUN:" | tee -a "$LOG_FILE"
  kubectl get pods | grep -E "go-plant|pid-controller" | tee -a "$LOG_FILE"
  echo "[PID] Last 5 log lines:" | tee -a "$LOG_FILE"
  kubectl logs deployment/pid-controller --tail=5 2>/dev/null | tee -a "$LOG_FILE"

  # Verify output
  if [ -f "$RESULTS_DIR/run${RUN}_stats.csv" ]; then
    FAIL_RATE=$(python3 -c "
import pandas as pd
df = pd.read_csv('$RESULTS_DIR/run${RUN}_stats.csv')
agg = df[df['Name']=='Aggregated'].iloc[0]
rate = agg['Failure Count']/agg['Request Count']*100
print(f'{rate:.2f}%')
" 2>/dev/null || echo "unknown")
    echo "[VERIFY] run${RUN}_stats.csv OK. Failure rate: $FAIL_RATE" | tee -a "$LOG_FILE"
  else
    echo "WARNING: run${RUN}_stats.csv not found." | tee -a "$LOG_FILE"
  fi

  echo "[DONE] Run $RUN complete." | tee -a "$LOG_FILE"

  if [ $RUN -lt $TOTAL_RUNS ]; then
    echo "[PAUSE] 10s before next reset..." | tee -a "$LOG_FILE"
    sleep 10
  fi
done

# --- Final summary ---
echo "" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"
echo "ALL $TOTAL_RUNS PID RUNS COMPLETE — $(date)" | tee -a "$LOG_FILE"
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