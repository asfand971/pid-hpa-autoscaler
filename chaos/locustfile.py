from locust import FastHttpUser, task, between, LoadTestShape
import time

class MicroserviceUser(FastHttpUser):
    # Simulate realistic network delays
    wait_time = between(0.1, 0.5)

    # 2-second timeout to trigger the retry storm condition
    network_timeout = 2.0
    connection_timeout = 2.0

    @task
    def work_endpoint(self):
        # Fire the initial request
        with self.client.get("/work", catch_response=True, timeout=self.network_timeout) as response:
            # If the request fails or times out, simulate the aggressive client retry
            if response.status_code == 0 or response.status_code >= 500 or response.elapsed.total_seconds() >= self.network_timeout:
                response.failure(f"Timeout/Error: Retrying...")
                # The Retry Storm mechanism: Immediate aggressive retry
                self.client.get("/work", name="/work (retry)", timeout=self.network_timeout)

class ThreePhaseChaosShape(LoadTestShape):
    """
    Defines the 25-minute (1500 seconds) experimental load profile.
    Phase 1: 0-300s (5 mins) -> 100 RPS baseline
    Phase 2: 301-900s (10 mins) -> 1000 RPS (Chaos Trigger)
    Phase 3: 901-1500s (10 mins) -> 100 RPS (Recovery)
    """
    def tick(self):
        run_time = self.get_run_time()

        if run_time < 300:
            # Phase 1: Stable Baseline
            return (100, 10) # 100 users, spawn 10/sec
        elif run_time < 900:
            # Phase 2: Metastable Failure Trigger (Retry Storm)
            return (1000, 50) # 1000 users, spawn 50/sec
        elif run_time <= 1500:
            # Phase 3: Recovery Phase
            return (100, 50)

        # Stop the test exactly at 25 minutes
        return None