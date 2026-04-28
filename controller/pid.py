"""
pid.py — Discrete PID Controller for Kubernetes Pod Autoscaling

Design decisions (dissertation Section 3.4.3):
  - Process variable: HTTP 503 rejection rate (req/s) from Prometheus
  - Setpoint: 0 req/s (zero tolerance for service rejection)
  - Control output: desired replica count (integer, clamped 1–10)
  - Loop interval: 15s (matches Prometheus scrape interval)
  - Anti-windup: integral clamping to ±MAX_REPLICAS
  - Dead band: ±DEAD_BAND req/s to suppress metric noise
  - Derivative: applied to process variable (not error) to avoid
    derivative kick on setpoint changes
"""


class PIDController:
    def __init__(
            self,
            kp: float = 0.5,
            ki: float = 0.05,
            kd: float = 0.1,
            setpoint: float = 0.0,
            min_replicas: int = 1,
            max_replicas: int = 10,
            dead_band: float = 2.0,
            dt: float = 15.0,
    ):
        """
        Parameters
        ----------
        kp : Proportional gain. Reacts to current magnitude of error.
        ki : Integral gain. Eliminates steady-state error. Kept low to
             limit windup during sustained overload.
        kd : Derivative gain. Dampens rapid metric changes to prevent
             thrashing. Applied to process variable, not error.
        setpoint : Target rejection rate in req/s. Zero = no rejections.
        min_replicas : Lower bound on output (matches HPA minReplicas).
        max_replicas : Upper bound on output (matches HPA maxReplicas).
        dead_band : Errors within ±dead_band are treated as zero.
                    Suppresses noise-driven scaling decisions.
        dt : Sampling interval in seconds. Must match loop cadence.
        """
        self.kp = kp
        self.ki = ki
        self.kd = kd
        self.setpoint = setpoint
        self.min_replicas = min_replicas
        self.max_replicas = max_replicas
        self.dead_band = dead_band
        self.dt = dt

        # Internal state
        self._integral = 0.0
        self._prev_process_variable = None

        # Anti-windup clamp: integral is bounded so that the integral
        # term alone cannot exceed the full output range.
        self._integral_max = float(max_replicas) / max(ki, 1e-9)
        self._integral_min = -self._integral_max

    def compute(self, process_variable: float, current_replicas: int) -> int:
        """
        Compute the next desired replica count.

        Parameters
        ----------
        process_variable : Current measured rejection rate (req/s).
        current_replicas : Current number of running replicas. Used as
                           the base for the PID output interpretation.

        Returns
        -------
        int : Desired replica count, clamped to [min_replicas, max_replicas].
        """
        # Raw error: positive means rejection rate exceeds setpoint
        raw_error = process_variable - self.setpoint

        # Dead band: suppress small errors caused by metric noise
        if abs(raw_error) <= self.dead_band:
            error = 0.0
        else:
            # Shift error toward zero by dead_band magnitude
            error = raw_error - (self.dead_band * (1 if raw_error > 0 else -1))

        # --- Proportional term ---
        proportional = self.kp * error

        # --- Integral term with anti-windup clamping ---
        self._integral += error * self.dt
        self._integral = max(self._integral_min, min(self._integral_max, self._integral))
        integral = self.ki * self._integral

        # --- Derivative term (on process variable to avoid kick) ---
        if self._prev_process_variable is None:
            derivative = 0.0
        else:
            dpv = (process_variable - self._prev_process_variable) / self.dt
            derivative = -self.kd * dpv  # negative: rising PV → reduce output

        self._prev_process_variable = process_variable

        # --- PID output: delta replicas on top of current count ---
        # u(t) represents the adjustment needed, not absolute replicas.
        # We interpret the output as: desired = current + u
        u = proportional + integral + derivative
        desired = current_replicas + u

        # Clamp and round to integer replica count
        desired = int(round(max(self.min_replicas, min(self.max_replicas, desired))))

        return desired

    def reset(self):
        """Reset internal state. Call between experimental runs."""
        self._integral = 0.0
        self._prev_process_variable = None