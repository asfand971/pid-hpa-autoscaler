#!/bin/bash
# =============================================================================
# run_baseline.sh
# Runs all 10 HPA control group experiments unattended.
# Handles pod reset, readiness check, and Locust execution automatically.
#
# Usage:
#   chmod +x run_baseline.sh
#   ./run_baseline.sh
#
# Run from the project root: /Users/asfand/Uni/lastSem/pid-hpa-autoscaler
# The tunnel must already be running in a separate terminal:
#   minikube service go-plant-service --url
# Pass the tunnel URL as an argument:
#   ./run_baseline.sh http://127.0.0.1:60268
# =============================================================================

set -e  # Exit on any error

# --- Configuration ---
PROJECT_DIR="/Users/asfand/Uni/lastSem/pid-hpa-autoscaler"
RESULTS_DIR="$PROJECT_DIR/results/baseline"
LOCUST_FILE="$PROJECT_DIR/chaos/locustfile.py"
VENV="$PROJECT_DIR/.venv/bin/activate"
TOTAL_RUNS=10
RUN_TIME="1500s"
LOG_FILE="$RESULTS_DIR/automation.log"

# --- Validate tunnel URL argument ---
if [ -z "$1" ]; then
  echo "ERROR: No tunnel URL provided."
  echo "Usage: ./run_baseline.sh http://127.0.0.1:PORT"
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
echo "HPA Baseline Experiment — $(date)" | tee -a "$LOG_FILE"
echo "Host: $HOST_URL" | tee -a "$LOG_FILE"
echo "Total runs: $TOTAL_RUNS" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"

# --- Verify service is reachable before starting ---
echo "[PREFLIGHT] Checking service at $HOST_URL/work ..." | tee -a "$LOG_FILE"
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$HOST_URL/work" || echo "000")
if [ "$RESPONSE" != "200" ]; then
  echo "ERROR: Service returned HTTP $RESPONSE. Check the tunnel is open and pod is running." | tee -a "$LOG_FILE"
  exit 1
fi
echo "[PREFLIGHT] Service OK (HTTP 200)" | tee -a "$LOG_FILE"

# --- Helper: wait for pod to be ready ---
wait_for_pod() {
  echo "[WAIT] Waiting for pod to be Ready..." | tee -a "$LOG_FILE"
  local attempts=0
  local max_attempts=60  # 60 x 5s = 5 minutes max wait

  while [ $attempts -lt $max_attempts ]; do
    READY=$(kubectl get pods --no-headers | grep "go-plant" | grep "1/1" | grep "Running" | wc -l | tr -d ' ')
    if [ "$READY" -ge "1" ]; then
      echo "[WAIT] Pod is Ready." | tee -a "$LOG_FILE"
      # Extra 10s buffer for HPA to reset its metrics
      echo "[WAIT] Waiting 10s for HPA metrics to reset..." | tee -a "$LOG_FILE"
      sleep 10
      return 0
    fi
    attempts=$((attempts + 1))
    echo "[WAIT] Attempt $attempts/$max_attempts — pod not ready yet, waiting 5s..." | tee -a "$LOG_FILE"
    sleep 5
  done

  echo "ERROR: Pod did not become ready after 5 minutes. Aborting." | tee -a "$LOG_FILE"
  exit 1
}

# --- Helper: reset pod between runs ---
reset_pod() {
  local run_num=$1
  echo "[RESET] Restarting pod after run $run_num..." | tee -a "$LOG_FILE"
  kubectl rollout restart deployment/go-plant >> "$LOG_FILE" 2>&1
  # Wait for old pod to terminate and new one to start
  sleep 15
  wait_for_pod
}

# --- Determine which run to start from ---
# Allows resuming if the script was interrupted
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

  # Reset pod before every run (including the first)
  # to ensure clean state with no residual connections
  reset_pod $((RUN - 1))

  # Verify service is still reachable after pod restart
  echo "[PREFLIGHT] Verifying service before run $RUN..." | tee -a "$LOG_FILE"
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$HOST_URL/work" || echo "000")
  if [ "$RESPONSE" != "200" ]; then
    echo "ERROR: Service returned HTTP $RESPONSE before run $RUN. Check tunnel is still open." | tee -a "$LOG_FILE"
    echo "Fix the issue then resume by running the script again — it will skip completed runs." | tee -a "$LOG_FILE"
    exit 1
  fi
  echo "[PREFLIGHT] Service OK (HTTP 200)" | tee -a "$LOG_FILE"

  # Log HPA state before run
  echo "[HPA] State before run $RUN:" | tee -a "$LOG_FILE"
  kubectl get hpa go-plant-hpa | tee -a "$LOG_FILE"

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

  # Verify output files exist
  if [ -f "$RESULTS_DIR/run${RUN}_stats.csv" ]; then
    TOTAL_REQS=$(tail -1 "$RESULTS_DIR/run${RUN}_stats.csv" | awk -F',' '{print $3}')
    echo "[VERIFY] run${RUN}_stats.csv exists. Total requests recorded: $TOTAL_REQS" | tee -a "$LOG_FILE"
  else
    echo "WARNING: run${RUN}_stats.csv not found — run may have failed." | tee -a "$LOG_FILE"
  fi

  echo "[DONE] Run $RUN complete." | tee -a "$LOG_FILE"

  # Brief pause between runs
  if [ $RUN -lt $TOTAL_RUNS ]; then
    echo "[PAUSE] 30s cooldown before next run..." | tee -a "$LOG_FILE"
    sleep 30
  fi
done

echo "" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"
echo "ALL $TOTAL_RUNS RUNS COMPLETE — $(date)" | tee -a "$LOG_FILE"
echo "Results saved to: $RESULTS_DIR" | tee -a "$LOG_FILE"
echo "=============================================" | tee -a "$LOG_FILE"

# Summary
echo "" | tee -a "$LOG_FILE"
echo "FILE SUMMARY:" | tee -a "$LOG_FILE"
ls -lh "$RESULTS_DIR"/*.csv | tee -a "$LOG_FILE"