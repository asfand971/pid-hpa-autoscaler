"""
prom_client.py — Prometheus query client for the PID controller.

Queries the in-cluster Prometheus for the HTTP 503 rejection rate,
which is the process variable fed into the PID controller.

The metric `plant_http_requests_rejected_total` is a counter exported
by the Go plant service. We use a 30-second rate window (2x the scrape
interval) to guarantee at least two data points exist for rate().
"""

import logging
import requests

logger = logging.getLogger(__name__)


class PrometheusClient:
    def __init__(self, url: str = "http://prometheus-kube-prometheus-prometheus.default.svc.cluster.local:9090"):
        self.url = url.rstrip("/")
        self.query_url = f"{self.url}/api/v1/query"

    def get_rejection_rate(self, window: str = "30s") -> float:
        """
        Query the per-second rate of HTTP 503 rejections over the given window.
        Uses 30s window (2x scrape interval) to guarantee rate() has 2+ samples.
        """
        query = f'rate(plant_http_requests_rejected_total[{window}])'
        try:
            response = requests.get(
                self.query_url,
                params={"query": query},
                timeout=5,
            )
            response.raise_for_status()
            data = response.json()

            results = data.get("data", {}).get("result", [])
            if not results:
                logger.warning("Prometheus returned no results for rejection rate query. Defaulting to 0.0.")
                return 0.0

            total_rate = sum(float(r["value"][1]) for r in results)
            logger.debug("Rejection rate: %.4f req/s (from %d series)", total_rate, len(results))
            return total_rate

        except requests.exceptions.RequestException as e:
            logger.error("Prometheus query failed: %s. Defaulting to 0.0.", e)
            return 0.0
        except (KeyError, ValueError, IndexError) as e:
            logger.error("Failed to parse Prometheus response: %s. Defaulting to 0.0.", e)
            return 0.0

    def health_check(self) -> bool:
        try:
            response = requests.get(f"{self.url}/-/healthy", timeout=3)
            return response.status_code == 200
        except requests.exceptions.RequestException:
            return False
