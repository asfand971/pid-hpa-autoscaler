"""
controller.py — Main control loop for the PID-based autoscaler.

Runs a continuous feedback loop:
  1. Query Prometheus for current HTTP rejection rate (process variable)
  2. Feed into PID controller to compute desired replica count
  3. Apply replica count to Kubernetes Deployment
  4. Sleep for one sampling interval (15s)

Environment variables (all optional, defaults shown):
  PROMETHEUS_URL      Prometheus base URL
  DEPLOYMENT_NAME     Target Deployment name       (default: go-plant)
  NAMESPACE           Kubernetes namespace          (default: default)
  LOOP_INTERVAL       Sampling interval in seconds  (default: 15)
  KP                  Proportional gain             (default: 0.5)
  KI                  Integral gain                 (default: 0.05)
  KD                  Derivative gain               (default: 0.1)
  SETPOINT            Target rejection rate req/s   (default: 0.0)
  MIN_REPLICAS        Minimum replica count         (default: 1)
  MAX_REPLICAS        Maximum replica count         (default: 10)
  DEAD_BAND           Dead band in req/s            (default: 2.0)
  LOG_LEVEL           Python logging level          (default: INFO)
"""

import logging
import os
import time

from pid import PIDController
from prom_client import PrometheusClient
from k8s_client import KubernetesClient


def get_env_float(key: str, default: float) -> float:
    try:
        return float(os.environ.get(key, default))
    except ValueError:
        return default


def get_env_int(key: str, default: int) -> int:
    try:
        return int(os.environ.get(key, default))
    except ValueError:
        return default


def setup_logging():
    level = os.environ.get("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
        level=getattr(logging, level, logging.INFO),
    )


def main():
    setup_logging()
    logger = logging.getLogger("pid-controller")

    # --- Configuration from environment ---
    prometheus_url  = os.environ.get("PROMETHEUS_URL", "http://prometheus-kube-prometheus-prometheus.default.svc.cluster.local:9090")
    deployment_name = os.environ.get("DEPLOYMENT_NAME", "go-plant")
    namespace       = os.environ.get("NAMESPACE", "default")
    loop_interval   = get_env_float("LOOP_INTERVAL", 15.0)
    kp              = get_env_float("KP", 0.5)
    ki              = get_env_float("KI", 0.05)
    kd              = get_env_float("KD", 0.1)
    setpoint        = get_env_float("SETPOINT", 0.0)
    min_replicas    = get_env_int("MIN_REPLICAS", 1)
    max_replicas    = get_env_int("MAX_REPLICAS", 10)
    dead_band       = get_env_float("DEAD_BAND", 2.0)

    logger.info("=== PID Autoscaler Starting ===")
    logger.info("Deployment:    %s/%s", namespace, deployment_name)
    logger.info("Prometheus:    %s", prometheus_url)
    logger.info("Gains:         Kp=%.3f  Ki=%.3f  Kd=%.3f", kp, ki, kd)
    logger.info("Setpoint:      %.2f req/s rejected", setpoint)
    logger.info("Replicas:      min=%d  max=%d", min_replicas, max_replicas)
    logger.info("Dead band:     ±%.2f req/s", dead_band)
    logger.info("Loop interval: %.0fs", loop_interval)

    # --- Initialise components ---
    pid = PIDController(
        kp=kp, ki=ki, kd=kd,
        setpoint=setpoint,
        min_replicas=min_replicas,
        max_replicas=max_replicas,
        dead_band=dead_band,
        dt=loop_interval,
    )
    prom = PrometheusClient(url=prometheus_url)
    k8s  = KubernetesClient(deployment_name=deployment_name, namespace=namespace)

    # --- Wait for Prometheus to be reachable ---
    logger.info("Waiting for Prometheus to be reachable...")
    while not prom.health_check():
        logger.warning("Prometheus not reachable. Retrying in 5s...")
        time.sleep(5)
    logger.info("Prometheus is reachable.")

    # --- Main control loop ---
    logger.info("Control loop started.")
    iteration = 0

    while True:
        loop_start = time.monotonic()
        iteration += 1

        try:
            # Step 1: Read process variable from Prometheus
            rejection_rate = prom.get_rejection_rate(window="30s")

            # Step 2: Read current replica count from Kubernetes
            current_replicas = k8s.get_current_replicas()
            ready_replicas   = k8s.get_ready_replicas()

            # Step 3: Compute PID output
            desired_replicas = pid.compute(
                process_variable=rejection_rate,
                current_replicas=current_replicas,
            )

            logger.info(
                "[iter=%d] rejection_rate=%.4f req/s | "
                "replicas: current=%d ready=%d desired=%d",
                iteration, rejection_rate,
                current_replicas, ready_replicas, desired_replicas,
            )

            # Step 4: Apply scaling decision
            k8s.set_replicas(desired_replicas)

        except Exception as e:
            logger.error("Unhandled error in control loop iteration %d: %s", iteration, e)

        # Sleep for the remainder of the interval
        elapsed = time.monotonic() - loop_start
        sleep_time = max(0.0, loop_interval - elapsed)
        time.sleep(sleep_time)


if __name__ == "__main__":
    main()