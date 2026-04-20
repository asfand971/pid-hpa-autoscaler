from locust import FastHttpUser, task, between, LoadTestShape
import time

# Maximum retries per request. Models aggressive client behaviour.
# Set to 3: each failed request generates up to 3 retry attempts.
# This gives an amplification factor of up to 4x, measurable and citable.
MAX_RETRIES = 3

class MicroserviceUser(FastHttpUser):
    # Realistic client think time between tasks
    wait_time = between(0.1, 0.5)

    # Long enough that the server must explicitly reject (503),
    # not silently queue until Locust gives up.
    network_timeout = 10.0
    connection_timeout = 5.0

    @task
    def work_endpoint(self):
        # Initial request
        with self.client.get(
                "/work",
                catch_response=True,
                timeout=self.network_timeout,
                name="/work"
        ) as response:
            if response.status_code == 503:
                response.failure("503: Overloaded — entering retry storm")
                self._retry_storm()
            elif response.status_code == 0:
                # Genuine network failure (shouldn't happen with semaphore)
                response.failure("Network error")
            elif response.status_code == 200:
                response.success()

    def _retry_storm(self):
        """
        Immediate, aggressive retry loop with no backoff.
        This is the sustaining mechanism of the metastable failure:
        each 503 triggers another request, amplifying load further.
        Retries are named separately so Locust tracks them independently,
        giving you a measurable amplification ratio in the CSV output.
        """
        for attempt in range(1, MAX_RETRIES + 1):
            # No sleep — models clients that retry immediately
            with self.client.get(
                    "/work",
                    catch_response=True,
                    timeout=self.network_timeout,
                    name=f"/work (retry {attempt})"
            ) as response:
                if response.status_code == 200:
                    response.success()
                    return  # Recovered — stop retrying
                elif response.status_code == 503:
                    response.failure(
                        f"503 on retry {attempt}/{MAX_RETRIES}: "
                        f"retry storm sustaining"
                    )
                    # Continue to next retry — this is the feedback loop
                else:
                    response.failure(
                        f"Unexpected status {response.status_code} "
                        f"on retry {attempt}"
                    )
                    return


class ThreePhaseChaosShape(LoadTestShape):
    """
    25-minute load profile with a controlled ramp.

    Phase 1 (0-300s):   100 users — stable baseline, CPU <60%
    Phase 2 (300-900s): ramp to 500 users — stresses one pod past
                        saturation, triggers 503s and retry storm.
                        500 is chosen so HPA has time to observe
                        CPU spike and issue scaling decisions before
                        total service collapse.
    Phase 3 (900-1500s): drop to 100 — recovery window.
                         Measures how long HPA takes to scale back down.
    """
    def tick(self):
        run_time = self.get_run_time()

        if run_time < 300:
            # Phase 1: Stable baseline
            return (100, 10)
        elif run_time < 360:
            # 60-second ramp at start of Phase 2 — gives HPA one full
            # scrape cycle to begin responding before peak load hits
            target = int(100 + (run_time - 300) / 60 * 400)
            return (target, 20)
        elif run_time < 900:
            # Phase 2: Sustained chaos
            return (500, 50)
        elif run_time <= 1500:
            # Phase 3: Recovery
            return (100, 50)

        return None