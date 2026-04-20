package main

import (
	"fmt"
	"log"
	"net/http"
	"sync/atomic"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/crypto/bcrypt"
)

// Maximum concurrent bcrypt operations before shedding load.
// Tuned so one pod saturates at ~60% CPU under moderate load.
// Adjust down if your Minikube node is slower.
const maxConcurrent = 50

var (
	activeRequests int64 // atomic counter

	httpRequestsTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "plant_http_requests_total",
		Help: "Total HTTP requests to /work",
	})
	httpRequestsRejected = promauto.NewCounter(prometheus.CounterOpts{
		Name: "plant_http_requests_rejected_total",
		Help: "Requests rejected with 503 due to overload",
	})
	concurrentRequests = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "plant_concurrent_requests",
		Help: "Requests currently being processed",
	})
)

func workHandler(w http.ResponseWriter, r *http.Request) {
	current := atomic.AddInt64(&activeRequests, 1)
	defer atomic.AddInt64(&activeRequests, -1)

	concurrentRequests.Set(float64(current))
	httpRequestsTotal.Inc()

	// Shed load immediately — respond fast so the client
	// gets a real HTTP error, not a silent timeout.
	if current > maxConcurrent {
		httpRequestsRejected.Inc()
		http.Error(w, "Service overloaded", http.StatusServiceUnavailable)
		return
	}

	password := []byte("chaos-engineering-test-password")
	_, err := bcrypt.GenerateFromPassword(password, 10)
	if err != nil {
		http.Error(w, "Server Error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, "Work complete")
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	// Also use the concurrency check for health — HPA readiness probe
	// should fail if the pod is saturated, preventing traffic routing
	// to a pod that will just immediately reject requests.
	if atomic.LoadInt64(&activeRequests) > maxConcurrent {
		http.Error(w, "Overloaded", http.StatusServiceUnavailable)
		return
	}
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, "OK")
}

func main() {
	http.HandleFunc("/work", workHandler)
	http.HandleFunc("/health", healthHandler)
	http.Handle("/metrics", promhttp.Handler())

	log.Println("Go Plant listening on :8080...")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
