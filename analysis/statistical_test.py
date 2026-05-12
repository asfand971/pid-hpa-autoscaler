#!/usr/bin/env python3
"""
Reproducible statistical analysis for the PID-HPA autoscaler dissertation.

This script regenerates:
- aggregate metrics per run
- aggregate HPA vs PID comparison
- Mann-Whitney U tests
- Cliff's delta effect sizes
- phase-based baseline/chaos/recovery summaries
- request-level recovery proxy
- dissertation figures

Expected input folders:
    results/baseline_v3/   # final HPA runs
    results/pid/           # final PID runs

Run from repo root:
    python analysis/statistical_test.py

Outputs:
    analysis/output/tables/
    analysis/output/figures/
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import matplotlib.pyplot as plt
import pandas as pd
from scipy.stats import mannwhitneyu


REPO_ROOT = Path(__file__).resolve().parents[1]
RESULTS_DIR = REPO_ROOT / "results"
HPA_DIR = RESULTS_DIR / "baseline_v3"
PID_DIR = RESULTS_DIR / "pid"

OUTPUT_DIR = REPO_ROOT / "analysis" / "output"
TABLES_DIR = OUTPUT_DIR / "tables"
FIGURES_DIR = OUTPUT_DIR / "figures"

BASELINE_END_SECONDS = 300
CHAOS_END_SECONDS = 900
RECOVERY_END_SECONDS = 1500

RECOVERY_SUSTAINED_SECONDS = 60
RECOVERY_THRESHOLDS = (1, 5, 10)


@dataclass(frozen=True)
class RunFiles:
    controller: str
    run_id: str
    stats_file: Path | None
    history_file: Path | None


def ensure_output_dirs() -> None:
    TABLES_DIR.mkdir(parents=True, exist_ok=True)
    FIGURES_DIR.mkdir(parents=True, exist_ok=True)


def normalise_column_name(column: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", column.strip().lower()).strip("_")


def normalise_columns(df: pd.DataFrame) -> pd.DataFrame:
    return df.rename(columns={col: normalise_column_name(str(col)) for col in df.columns})


def find_csv_files(folder: Path, suffix: str) -> list[Path]:
    if not folder.exists():
        raise FileNotFoundError(f"Required results folder does not exist: {folder}")

    return sorted(
        path
        for path in folder.rglob("*.csv")
        if path.name.endswith(suffix) and not path.name.startswith("._")
    )


def infer_run_id(path: Path) -> str:
    name = path.stem
    for token in ("_stats_history", "_stats", "stats_history", "stats"):
        name = name.replace(token, "")
    name = name.strip("_- ")
    return name or path.parent.name or path.stem


def discover_run_files(controller: str, folder: Path) -> list[RunFiles]:
    stats_files = find_csv_files(folder, "_stats.csv")
    history_files = find_csv_files(folder, "_stats_history.csv")

    by_run: dict[str, dict[str, Path | None]] = {}

    for path in stats_files:
        run_id = infer_run_id(path)
        by_run.setdefault(run_id, {"stats": None, "history": None})["stats"] = path

    for path in history_files:
        run_id = infer_run_id(path)
        by_run.setdefault(run_id, {"stats": None, "history": None})["history"] = path

    return [
        RunFiles(
            controller=controller,
            run_id=run_id,
            stats_file=paths["stats"],
            history_file=paths["history"],
        )
        for run_id, paths in sorted(by_run.items())
    ]


def read_csv(path: Path) -> pd.DataFrame:
    return normalise_columns(pd.read_csv(path))


def find_col(df: pd.DataFrame, candidates: Iterable[str]) -> str | None:
    candidate_set = {normalise_column_name(candidate) for candidate in candidates}
    for column in df.columns:
        if column in candidate_set:
            return column
    return None


def find_required_col(df: pd.DataFrame, candidates: Iterable[str], context: str) -> str:
    column = find_col(df, candidates)
    if column is None:
        raise KeyError(
            f"Could not find required column for {context}. "
            f"Tried {list(candidates)}. Available columns: {list(df.columns)}"
        )
    return column


def get_total_row(stats: pd.DataFrame) -> pd.Series:
    """
    Return Locust's aggregate row.

    Locust commonly uses 'Aggregated' as the total row. If not found,
    this falls back to the final row.
    """
    name_col = find_col(stats, ("name", "request_name"))

    if name_col is not None:
        total_candidates = stats[
            stats[name_col]
            .astype(str)
            .str.lower()
            .isin(("aggregated", "total", "none", "nan"))
        ]

        if not total_candidates.empty:
            return total_candidates.iloc[-1]

    return stats.iloc[-1]


def numeric_value(row: pd.Series, candidates: Iterable[str], default: float = 0.0) -> float:
    for candidate in candidates:
        key = normalise_column_name(candidate)
        if key in row.index and pd.notna(row[key]):
            try:
                return float(row[key])
            except (TypeError, ValueError):
                continue
    return default


def aggregate_metrics_for_run(run_files: RunFiles) -> dict[str, float | str]:
    if run_files.stats_file is None:
        raise FileNotFoundError(
            f"Missing stats CSV for {run_files.controller} {run_files.run_id}"
        )

    stats = read_csv(run_files.stats_file)
    total = get_total_row(stats)

    request_count = numeric_value(total, ("request_count", "num_requests", "requests"))
    failure_count = numeric_value(total, ("failure_count", "num_failures", "failures"))

    requests_per_s = numeric_value(total, ("requests_s", "requests/s", "reqs_s", "rps"))
    failures_per_s = numeric_value(total, ("failures_s", "failures/s", "fail_s"))

    average_response_time = numeric_value(
        total,
        ("average_response_time", "avg_response_time", "avg_response_time_ms"),
    )
    median_response_time = numeric_value(
        total,
        ("median_response_time", "median_response_time_ms", "50", "50_percentile"),
    )
    p95_response_time = numeric_value(
        total,
        ("95", "95_percentile", "p95", "p95_response_time", "95_response_time"),
    )
    p99_response_time = numeric_value(
        total,
        ("99", "99_percentile", "p99", "p99_response_time", "99_response_time"),
    )

    if request_count <= 0 and requests_per_s > 0:
        request_count = requests_per_s * RECOVERY_END_SECONDS

    if failures_per_s <= 0 and failure_count > 0:
        failures_per_s = failure_count / RECOVERY_END_SECONDS

    failure_rate = failure_count / request_count if request_count > 0 else math.nan
    effective_successful_requests_s = (
        requests_per_s * (1 - failure_rate) if pd.notna(failure_rate) else math.nan
    )

    return {
        "controller": run_files.controller,
        "run_id": run_files.run_id,
        "stats_file": str(run_files.stats_file.relative_to(REPO_ROOT)),
        "request_count": request_count,
        "failure_count": failure_count,
        "failure_rate": failure_rate,
        "failure_rate_percent": failure_rate * 100,
        "failures_per_s": failures_per_s,
        "average_response_time_ms": average_response_time,
        "median_response_time_ms": median_response_time,
        "p95_response_time_ms": p95_response_time,
        "p99_response_time_ms": p99_response_time,
        "requests_per_s": requests_per_s,
        "effective_successful_requests_s": effective_successful_requests_s,
    }


def load_history(run_files: RunFiles) -> pd.DataFrame | None:
    if run_files.history_file is None:
        return None

    history = read_csv(run_files.history_file)
    timestamp_col = find_required_col(
        history,
        ("timestamp", "time"),
        f"timestamp in {run_files.history_file}",
    )

    name_col = find_col(history, ("name", "request_name"))
    if name_col is not None:
        aggregate_rows = history[
            history[name_col]
            .astype(str)
            .str.lower()
            .isin(("aggregated", "total", "none", "nan"))
        ]

        if not aggregate_rows.empty:
            history = aggregate_rows.copy()

    history = history.sort_values(timestamp_col).reset_index(drop=True)
    first_timestamp = float(history[timestamp_col].iloc[0])

    history["elapsed_s"] = history[timestamp_col].astype(float) - first_timestamp
    history["controller"] = run_files.controller
    history["run_id"] = run_files.run_id
    history["history_file"] = str(run_files.history_file.relative_to(REPO_ROOT))

    return history


def prepare_history_metrics(history: pd.DataFrame) -> pd.DataFrame:
    requests_col = find_col(history, ("requests_s", "requests/s", "reqs_s", "rps"))
    failures_col = find_col(history, ("failures_s", "failures/s", "fail_s"))
    p50_col = find_col(
        history,
        ("50", "50_percentile", "median_response_time", "median_response_time_ms"),
    )
    p95_col = find_col(
        history,
        ("95", "95_percentile", "p95", "p95_response_time", "95_response_time"),
    )

    output = history[["controller", "run_id", "elapsed_s"]].copy()

    output["requests_per_s"] = (
        history[requests_col].astype(float) if requests_col else 0.0
    )
    output["failures_per_s"] = (
        history[failures_col].astype(float) if failures_col else 0.0
    )
    output["p50_response_time_ms"] = (
        history[p50_col].astype(float) if p50_col else math.nan
    )
    output["p95_response_time_ms"] = (
        history[p95_col].astype(float) if p95_col else math.nan
    )

    output["phase"] = output["elapsed_s"].apply(phase_for_elapsed_seconds)
    return output


def phase_for_elapsed_seconds(elapsed_s: float) -> str:
    if elapsed_s < BASELINE_END_SECONDS:
        return "Baseline"
    if elapsed_s < CHAOS_END_SECONDS:
        return "Chaos"
    if elapsed_s <= RECOVERY_END_SECONDS:
        return "Recovery"
    return "Post-run"


def relative_change(pid_value: float, hpa_value: float) -> float:
    if hpa_value == 0:
        return math.nan
    return ((pid_value - hpa_value) / hpa_value) * 100


def cliffs_delta_direct(hpa_values: pd.Series, pid_values: pd.Series) -> float:
    """
    Cliff's delta with direction as PID relative to HPA.

    Positive value means PID values are generally larger.
    Negative value means PID values are generally smaller.
    """
    greater = 0
    lesser = 0

    for hpa in hpa_values:
        for pid in pid_values:
            if pid > hpa:
                greater += 1
            elif pid < hpa:
                lesser += 1

    return (greater - lesser) / (len(hpa_values) * len(pid_values))


def effect_size_label(delta: float) -> str:
    abs_delta = abs(delta)

    if abs_delta < 0.147:
        return "negligible"
    if abs_delta < 0.33:
        return "small"
    if abs_delta < 0.474:
        return "medium"
    return "large"


def aggregate_summary(aggregate_df: pd.DataFrame) -> pd.DataFrame:
    metrics = [
        ("Failure rate (%)", "failure_rate_percent"),
        ("Failures/s", "failures_per_s"),
        ("Average response time (ms)", "average_response_time_ms"),
        ("Median response time (ms)", "median_response_time_ms"),
        ("p95 response time (ms)", "p95_response_time_ms"),
        ("p99 response time (ms)", "p99_response_time_ms"),
        ("Raw requests/s", "requests_per_s"),
    ]

    rows = []
    grouped = aggregate_df.groupby("controller")

    for label, column in metrics:
        hpa_mean = grouped[column].mean().get("HPA", math.nan)
        pid_mean = grouped[column].mean().get("PID", math.nan)

        rows.append(
            {
                "metric": label,
                "hpa_mean": hpa_mean,
                "pid_mean": pid_mean,
                "relative_change_with_pid_percent": relative_change(pid_mean, hpa_mean),
            }
        )

    hpa_mean_rps = grouped["requests_per_s"].mean().get("HPA", math.nan)
    pid_mean_rps = grouped["requests_per_s"].mean().get("PID", math.nan)

    hpa_mean_failure_rate = grouped["failure_rate"].mean().get("HPA", math.nan)
    pid_mean_failure_rate = grouped["failure_rate"].mean().get("PID", math.nan)

    hpa_effective_rps = hpa_mean_rps * (1 - hpa_mean_failure_rate)
    pid_effective_rps = pid_mean_rps * (1 - pid_mean_failure_rate)

    rows.append(
        {
            "metric": "Effective successful requests/s",
            "hpa_mean": hpa_effective_rps,
            "pid_mean": pid_effective_rps,
            "relative_change_with_pid_percent": relative_change(
                pid_effective_rps,
                hpa_effective_rps,
            ),
        }
    )

    return pd.DataFrame(rows)

def statistical_tests(aggregate_df: pd.DataFrame) -> pd.DataFrame:
    metrics = [
        ("Failure rate", "failure_rate_percent"),
        ("Failures/s", "failures_per_s"),
        ("Average response time", "average_response_time_ms"),
        ("Median response time", "median_response_time_ms"),
        ("p95 latency", "p95_response_time_ms"),
        ("p99 latency", "p99_response_time_ms"),
        ("Requests/s", "requests_per_s"),
        ("Effective successful requests/s", "effective_successful_requests_s"),
    ]

    rows = []

    for label, column in metrics:
        hpa_values = aggregate_df.loc[
            aggregate_df["controller"] == "HPA", column
        ].dropna()
        pid_values = aggregate_df.loc[
            aggregate_df["controller"] == "PID", column
        ].dropna()

        if hpa_values.empty or pid_values.empty:
            continue

        result = mannwhitneyu(hpa_values, pid_values, alternative="two-sided")
        delta = cliffs_delta_direct(hpa_values, pid_values)

        rows.append(
            {
                "metric": label,
                "u_statistic": result.statistic,
                "p_value": result.pvalue,
                "cliffs_delta_pid_relative_to_hpa": delta,
                "effect_size": effect_size_label(delta),
                "hpa_n": len(hpa_values),
                "pid_n": len(pid_values),
            }
        )

    return pd.DataFrame(rows)


def phase_summary(history_metrics: pd.DataFrame) -> pd.DataFrame:
    valid = history_metrics[
        history_metrics["phase"].isin(("Baseline", "Chaos", "Recovery"))
    ].copy()

    valid["row_failure_rate_percent"] = (
                                                valid["failures_per_s"] / valid["requests_per_s"].replace(0, math.nan)
                                        ) * 100

    summary = (
        valid.groupby(["controller", "phase"], as_index=False)
        .agg(
            mean_rps=("requests_per_s", "mean"),
            mean_failures_s=("failures_per_s", "mean"),
            mean_p50_ms=("p50_response_time_ms", "mean"),
            mean_p95_ms=("p95_response_time_ms", "mean"),
            failure_rate_percent=("row_failure_rate_percent", "mean"),
        )
    )

    phase_order = pd.CategoricalDtype(
        ["Baseline", "Chaos", "Recovery"],
        ordered=True,
    )
    controller_order = pd.CategoricalDtype(
        ["HPA", "PID"],
        ordered=True,
    )

    summary["phase"] = summary["phase"].astype(phase_order)
    summary["controller"] = summary["controller"].astype(controller_order)

    return summary.sort_values(["phase", "controller"]).reset_index(drop=True)

def recovery_proxy_for_run(run_history: pd.DataFrame, threshold: float) -> float | None:
    recovery = run_history[run_history["elapsed_s"] >= CHAOS_END_SECONDS].copy()

    if recovery.empty:
        return None

    recovery = recovery.sort_values("elapsed_s").reset_index(drop=True)

    for idx in range(len(recovery)):
        window_start = recovery.loc[idx, "elapsed_s"]
        window_end = window_start + RECOVERY_SUSTAINED_SECONDS

        window = recovery[
            (recovery["elapsed_s"] >= window_start)
            & (recovery["elapsed_s"] < window_end)
            ]

        if window.empty:
            continue

        if window["elapsed_s"].max() - window_start < RECOVERY_SUSTAINED_SECONDS - 1:
            continue

        if (window["failures_per_s"] <= threshold).all():
            return float(window_start - CHAOS_END_SECONDS)

    return None


def recovery_proxy_summary(history_metrics: pd.DataFrame) -> pd.DataFrame:
    rows = []

    for (controller, run_id), run_history in history_metrics.groupby(
            ["controller", "run_id"]
    ):
        for threshold in RECOVERY_THRESHOLDS:
            rows.append(
                {
                    "controller": controller,
                    "run_id": run_id,
                    "criterion": (
                        f"failures/s <= {threshold} "
                        f"for {RECOVERY_SUSTAINED_SECONDS}s"
                    ),
                    "threshold": threshold,
                    "recovery_seconds": recovery_proxy_for_run(
                        run_history,
                        threshold,
                    ),
                }
            )

    per_run = pd.DataFrame(rows)
    per_run.to_csv(TABLES_DIR / "recovery_proxy_per_run.csv", index=False)

    summary = (
        per_run.groupby(["criterion", "controller"], as_index=False)[
            "recovery_seconds"
        ]
        .mean()
        .pivot(index="criterion", columns="controller", values="recovery_seconds")
        .reset_index()
    )

    if "HPA" in summary.columns and "PID" in summary.columns:
        summary["difference_pid_minus_hpa_seconds"] = summary["PID"] - summary["HPA"]

    return summary


def save_table(df: pd.DataFrame, filename: str) -> None:
    df.to_csv(TABLES_DIR / filename, index=False)


def plot_run_metric(
        aggregate_df: pd.DataFrame,
        column: str,
        ylabel: str,
        title: str,
        filename: str,
) -> None:
    plt.figure(figsize=(8, 5))

    for controller in ("HPA", "PID"):
        subset = aggregate_df[
            aggregate_df["controller"] == controller
            ].reset_index(drop=True)

        plt.plot(
            range(1, len(subset) + 1),
            subset[column],
            marker="o",
            label=controller,
        )

    plt.xlabel("Run")
    plt.ylabel(ylabel)
    plt.title(title)
    plt.legend()
    plt.tight_layout()
    plt.savefig(FIGURES_DIR / filename, dpi=300)
    plt.close()


def plot_history_mean(
        history_metrics: pd.DataFrame,
        column: str,
        ylabel: str,
        title: str,
        filename: str,
) -> None:
    binned = history_metrics.copy()
    binned["elapsed_s_bin"] = (binned["elapsed_s"] // 10) * 10

    summary = (
        binned.groupby(["controller", "elapsed_s_bin"], as_index=False)[column]
        .mean()
        .sort_values(["controller", "elapsed_s_bin"])
    )

    plt.figure(figsize=(9, 5))

    for controller in ("HPA", "PID"):
        subset = summary[summary["controller"] == controller]
        plt.plot(subset["elapsed_s_bin"], subset[column], label=controller)

    for boundary in (BASELINE_END_SECONDS, CHAOS_END_SECONDS):
        plt.axvline(boundary, linestyle="--", linewidth=1)

    plt.xlabel("Elapsed time (s)")
    plt.ylabel(ylabel)
    plt.title(title)
    plt.legend()
    plt.tight_layout()
    plt.savefig(FIGURES_DIR / filename, dpi=300)
    plt.close()


def plot_recovery_proxy(per_run_recovery_file: Path) -> None:
    per_run = pd.read_csv(per_run_recovery_file)

    if per_run.empty:
        return

    for criterion in per_run["criterion"].dropna().unique():
        subset = per_run[per_run["criterion"] == criterion]

        values = [
            subset.loc[
                subset["controller"] == "HPA",
                "recovery_seconds",
            ].dropna(),
            subset.loc[
                subset["controller"] == "PID",
                "recovery_seconds",
            ].dropna(),
        ]

        if all(series.empty for series in values):
            continue

        threshold = subset["threshold"].iloc[0]

        plt.figure(figsize=(7, 5))
        plt.boxplot(values, tick_labels=["HPA", "PID"])
        plt.ylabel("Recovery proxy time (s)")
        plt.title(f"Request-level recovery proxy: failures/s <= {threshold}")
        plt.tight_layout()
        plt.savefig(FIGURES_DIR / f"recovery_proxy_threshold_{threshold}.png", dpi=300)
        plt.close()


def generate_figures(
        aggregate_df: pd.DataFrame,
        summary_df: pd.DataFrame,
        history_metrics: pd.DataFrame,
) -> None:
    plot_run_metric(
        aggregate_df,
        "failure_rate_percent",
        "Failure rate (%)",
        "Failure rate across ten experimental runs",
        "figure_4_failure_rate_runs.png",
    )

    plot_run_metric(
        aggregate_df,
        "average_response_time_ms",
        "Average response time (ms)",
        "Aggregate latency across experimental runs",
        "figure_5_average_latency_runs.png",
    )

    plot_run_metric(
        aggregate_df,
        "requests_per_s",
        "Requests/s",
        "Achieved throughput across experimental runs",
        "figure_6_throughput_runs.png",
    )

    effective_row = summary_df[
        summary_df["metric"] == "Effective successful requests/s"
        ]

    if not effective_row.empty:
        plt.figure(figsize=(7, 5))
        plt.bar(
            ["HPA", "PID"],
            [
                effective_row["hpa_mean"].iloc[0],
                effective_row["pid_mean"].iloc[0],
            ],
        )
        plt.ylabel("Successful requests/s")
        plt.title("Effective successful requests/s")
        plt.tight_layout()
        plt.savefig(FIGURES_DIR / "effective_successful_rps.png", dpi=300)
        plt.close()

    if not history_metrics.empty:
        plot_history_mean(
            history_metrics,
            "failures_per_s",
            "Mean failures/s",
            "Mean failure intensity over time",
            "figure_7_mean_failure_intensity_over_time.png",
        )

        plot_history_mean(
            history_metrics,
            "p95_response_time_ms",
            "Mean p95 response time (ms)",
            "Mean p95 latency over time",
            "figure_8_mean_p95_latency_over_time.png",
        )

    recovery_file = TABLES_DIR / "recovery_proxy_per_run.csv"

    if recovery_file.exists():
        plot_recovery_proxy(recovery_file)


def print_key_outputs(
        summary_df: pd.DataFrame,
        stats_df: pd.DataFrame,
        phase_df: pd.DataFrame,
        recovery_df: pd.DataFrame,
) -> None:
    pd.set_option("display.max_columns", 20)
    pd.set_option("display.width", 160)

    print("\nAggregate comparison")
    print(summary_df.round(4).to_string(index=False))

    print("\nStatistical tests")
    print(stats_df.round(6).to_string(index=False))

    print("\nPhase-based summary")
    print(phase_df.round(4).to_string(index=False))

    print("\nRequest-level recovery proxy")
    print(recovery_df.round(4).to_string(index=False))

    print(f"\nSaved CSV tables to: {TABLES_DIR}")
    print(f"Saved figures to: {FIGURES_DIR}")


def main() -> None:
    ensure_output_dirs()

    run_files = discover_run_files("HPA", HPA_DIR) + discover_run_files("PID", PID_DIR)

    if not run_files:
        raise RuntimeError("No Locust CSV files found under results/baseline_v3 or results/pid")

    aggregate_rows = [
        aggregate_metrics_for_run(run)
        for run in run_files
        if run.stats_file is not None
    ]

    aggregate_df = pd.DataFrame(aggregate_rows)
    save_table(aggregate_df, "aggregate_metrics_per_run.csv")

    summary_df = aggregate_summary(aggregate_df)
    save_table(summary_df, "aggregate_comparison_summary.csv")

    stats_df = statistical_tests(aggregate_df)
    save_table(stats_df, "mann_whitney_cliffs_delta.csv")

    history_frames = []

    for run in run_files:
        history = load_history(run)

        if history is not None:
            history_frames.append(prepare_history_metrics(history))

    if history_frames:
        history_metrics = pd.concat(history_frames, ignore_index=True)
    else:
        history_metrics = pd.DataFrame(
            columns=[
                "controller",
                "run_id",
                "elapsed_s",
                "requests_per_s",
                "failures_per_s",
                "p50_response_time_ms",
                "p95_response_time_ms",
                "phase",
            ]
        )

    save_table(history_metrics, "history_metrics_all_runs.csv")

    phase_df = phase_summary(history_metrics) if not history_metrics.empty else pd.DataFrame()
    save_table(phase_df, "phase_based_summary.csv")

    recovery_df = (
        recovery_proxy_summary(history_metrics)
        if not history_metrics.empty
        else pd.DataFrame()
    )
    save_table(recovery_df, "recovery_proxy_summary.csv")

    generate_figures(aggregate_df, summary_df, history_metrics)

    print_key_outputs(summary_df, stats_df, phase_df, recovery_df)


if __name__ == "__main__":
    main()