.PHONY: cluster-up cluster-down build-plant deploy-plant deploy-metrics hpa-on hpa-off run-chaos clean

# ==========================================
# INFRASTRUCTURE (Sprint 1)
# ==========================================
cluster-up:
	@echo "Bootstrapping Minikube (4 CPUs, 6GB RAM)..."
	minikube start --cpus=4 --memory=6g --addons=metrics-server

cluster-down:
	minikube delete

deploy-metrics:
	@echo "Installing Prometheus Stack via Helm..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack -f infrastructure/prometheus-values.yaml

# ==========================================
# PLANT COMPONENT (Sprint 1)
# ==========================================
build-plant:
	@echo "Building Go Plant image inside Minikube..."
	eval $$(minikube docker-env) && docker build -t go-plant:v1 ./plant

deploy-plant: build-plant
	@echo "Deploying Go Plant..."
	kubectl apply -f plant/deployment.yaml
	kubectl apply -f plant/service.yaml

# ==========================================
# EXPERIMENT CONTROLS (Sprint 2 & 3)
# ==========================================
hpa-on:
	@echo "Applying Kubernetes HPA (Control Group)..."
	kubectl apply -f plant/plant-hpa.yaml

hpa-off:
	@echo "Deleting HPA to isolate PID Controller..."
	kubectl delete hpa go-plant-hpa --ignore-not-found=true

run-chaos:
	@echo "Starting Locust Chaos Test..."
	locust -f chaos/locustfile.py --host=http://$$(minikube ip):30080

# ==========================================
# CLEANUP
# ==========================================
clean:
	kubectl delete -f plant/deployment.yaml --ignore-not-found=true
	kubectl delete -f plant/service.yaml --ignore-not-found=true
	make hpa-off