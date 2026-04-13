package main

import (
	"fmt"
	"log"
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/crypto/bcrypt"
)

// Custom Prometheus metric to track Locust RPS
var (
	httpRequestsTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "plant_http_requests_total",
		Help: "Total number of HTTP requests processed by the /work endpoint",
	})
)

func workHandler(w http.ResponseWriter, r *http.Request) {
	httpRequestsTotal.Inc()

	// Cost 10 bcrypt hash to intentionally saturate CPU
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
