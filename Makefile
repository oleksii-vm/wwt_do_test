.PHONY: up down logs test build kind-up kind-down kind-test kind-tls

BASE_URL := http://localhost:8080
KIND_CLUSTER := devops-test
KIND_URL := http://localhost

build:
	docker compose build

up:
	docker compose up -d --build
	@echo "Waiting for services to be healthy..."
	@for i in $$(seq 1 30); do \
		status=$$(docker inspect --format='{{.State.Health.Status}}' proxy 2>/dev/null || echo "starting"); \
		if [ "$$status" = "healthy" ]; then echo "proxy is healthy"; exit 0; fi; \
		sleep 1; \
	done; \
	echo "Timed out waiting for proxy to become healthy"; \
	docker compose ps; \
	exit 1

down:
	docker compose down -v

logs:
	docker compose logs -f

test:
	@echo "== 1. /healthz returns 200 with expected JSON =="
	@curl -sf $(BASE_URL)/healthz | tee /tmp/healthz.json
	@echo ""
	@grep -q '"status":"ok"' /tmp/healthz.json && echo "OK: status=ok" || (echo "FAIL: status not ok" && exit 1)

	@echo ""
	@echo "== 2. X-Request-ID is generated when not sent =="
	@resp=$$(curl -sD - -o /dev/null $(BASE_URL)/healthz); \
	echo "$$resp" | grep -i "X-Request-ID" && echo "OK: X-Request-ID present" || (echo "FAIL: X-Request-ID missing" && exit 1)

	@echo ""
	@echo "== 3. X-Request-ID is passed through when sent =="
	@resp=$$(curl -sD - -o /dev/null -H "X-Request-ID: test-fixed-id-123" $(BASE_URL)/healthz); \
	echo "$$resp" | grep -i "X-Request-ID: test-fixed-id-123" && echo "OK: X-Request-ID passed through" || (echo "FAIL: X-Request-ID not passed through" && exit 1)

	@echo ""
	@echo "== 4. Rate limit: >10 req/sec from one client returns 429 =="
	@codes=$$(for i in $$(seq 1 30); do curl -s -o /dev/null -w "%{http_code}\n" $(BASE_URL)/healthz & done; wait); \
	echo "$$codes" | sort | uniq -c; \
	echo "$$codes" | grep -q 429 && echo "OK: got 429 under load" || (echo "FAIL: no 429 seen" && exit 1)

	@echo ""
	@echo "All tests passed."

## --- Bonus: Kind/Kubernetes track ---
## Uses plain kubectl manifests by default (see README for the helm alternative).

kind-up:
	kind create cluster --name $(KIND_CLUSTER) --config k8s/kind-config.yaml
	docker build -t app:local ./app
	kind load docker-image app:local --name $(KIND_CLUSTER)
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml
	@echo "Waiting for ingress-nginx to be ready..."
	kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=120s
	kubectl apply -f k8s/deployment.yaml
	kubectl apply -f k8s/service.yaml
	kubectl apply -f k8s/ingress.yaml
	kubectl rollout status deployment/app --timeout=90s

kind-test:
	kubectl get pods,svc,ingress
	curl -sf $(KIND_URL)/healthz | tee /tmp/kind-healthz.json
	@echo ""
	@grep -q '"status":"ok"' /tmp/kind-healthz.json && echo "OK: status=ok" || (echo "FAIL" && exit 1)

kind-tls:
	@mkdir -p /tmp/app-tls
	openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout /tmp/app-tls/tls.key -out /tmp/app-tls/tls.crt \
		-subj "/CN=localhost/O=localhost"
	kubectl create secret tls app-tls \
		--cert=/tmp/app-tls/tls.crt --key=/tmp/app-tls/tls.key \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f k8s/ingress-tls.yaml
	@echo "Test with: curl -sk https://localhost/healthz"

kind-down:
	kind delete cluster --name $(KIND_CLUSTER)
