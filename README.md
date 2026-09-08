# Tiny service behind a reverse proxy

Test task: a tiny app running behind nginx as a reverse proxy, with
request-id passthrough and rate limiting. Docker Compose is the main/required
part, Kind + Ingress is the bonus on top.

Repo layout, roughly:

```
app/            - the tiny node app (no deps, just http module)
nginx/          - nginx.conf for the reverse proxy
k8s/            - bonus: kind config + deployment/service/ingress manifests
docker-compose.yml
Makefile
.env / .env.example
```

## How it's wired

```
client -> nginx :8080 (only port exposed) -> app :3000 (internal only)
```

App just answers `/` and `/healthz` with:
```json
{"status":"ok","service":"app","env":"local"}
```
`env` comes from `ENV_NAME`, which you set in `.env`.

nginx in front does three things:
- passes `X-Request-ID` through if the client sent one, otherwise generates
  one itself and returns it in the response
- is literally the only container with a published port (8080)
- rate limits per client IP - more than 10 req/sec and you start getting 429s

## Requirements

Docker + Compose v2, curl, make. For the bonus you'll also want kind and
kubectl (helm optional, see below).

## Running it (Compose)

```bash
cp .env.example .env   # tweak ENV_NAME if you want
make up
make test
```

`make up` builds and starts both containers and waits until nginx reports
healthy before returning. `make test` runs a few checks: healthz returns
200 with the right JSON, request-id gets generated when missing, gets
passed through when present, and a burst of requests triggers some 429s.

Logs: `make logs`. Stop everything: `make down` (also removes the network).

If you want to poke at it manually:

```bash
curl -s http://localhost:8080/healthz

# check request-id header
curl -sD - -o /dev/null http://localhost:8080/healthz | grep -i x-request-id

# hammer it a bit, see the 429s show up
for i in $(seq 1 20); do curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/healthz; done | sort | uniq -c
```

`docker ps` should show both containers as `(healthy)`.

Change `ENV_NAME` in `.env` and run `make up` again to see it reflected in
the response - useful for checking the env wiring actually works and isn't
just hardcoded.

## Bonus: Kind + Ingress

This spins up a local kind cluster, loads the app image into it, installs
ingress-nginx, and applies the Deployment/Service/Ingress. All wrapped in
`make kind-up`, but here's what it's doing step by step in case you want to
run it by hand or just understand it:

**1. Create the cluster**

`k8s/kind-config.yaml` maps ports 80/443 from the ingress controller
straight to your host, so you end up hitting `http://localhost/healthz`
directly, no weird extra port.

```bash
kind create cluster --name devops-test --config k8s/kind-config.yaml
```

(if 80/443 are already taken on your machine, just change the hostPort in
that file and adjust the curl commands below accordingly)

**2. Build the app image and get it into the cluster**

kind runs its own docker-in-docker-ish node, so a locally built image isn't
visible to it automatically - you have to load it in:

```bash
docker build -t app:local ./app
kind load docker-image app:local --name devops-test
```

**3. Install ingress-nginx**

Either plain kubectl (this is what `make kind-up` actually runs):

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=120s
```

or if you'd rather use helm:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostPort.enabled=true \
  --set controller.service.type=ClusterIP \
  --set controller.nodeSelector."ingress-ready"=true \
  --set-string controller.nodeSelector."kubernetes\.io/os"=linux
```

Both end up in the same place - ingress-nginx running and ready.

**4. Apply the app manifests**

```bash
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
```

**5. Check it**

```bash
kubectl get pods,svc,ingress
curl -s http://localhost/healthz
```

Should give you the same JSON as the Compose version, just with
`"env":"kind"` this time.

Tear down with `kind delete cluster --name devops-test` (or `make kind-down`).

### Self-signed TLS (optional, didn't have to do this but figured why not)

Generate a cert, stuff it into a k8s Secret, apply the TLS ingress variant:

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/tls.key -out /tmp/tls.crt -subj "/CN=localhost/O=localhost"

kubectl create secret tls app-tls --cert=/tmp/tls.crt --key=/tmp/tls.key

kubectl apply -f k8s/ingress-tls.yaml

curl -sk https://localhost/healthz
```

`-k` is needed because it's a self-signed cert, curl won't trust it by
default. `k8s/ingress-tls.yaml` is a separate Ingress object from the plain
HTTP one, so both can run at the same time - didn't want to break the
non-TLS path just to add this.

`make kind-tls` does all of the above in one go if you don't want to type
it out.

## Notes on some of the decisions

- App has zero npm dependencies on purpose - just Node's built-in `http`
  module. Keeps the image small and avoids `npm install` during the build.
- The rate limit uses `nodelay` with no `burst`, so it's a pretty hard
  cutoff - go over 10 req/sec and you're immediately getting 429s, no
  grace period. Task said "more than 10 req/sec -> 429" so went with the
  literal reading. A `burst=5 nodelay` setup would be a bit more forgiving
  if that's preferred instead.
- X-Request-ID logic is an nginx `map` block - if the incoming header is
  empty, fall back to nginx's own `$request_id`, otherwise just pass
  through whatever the client sent.
- Compose healthchecks: nginx `depends_on: app: condition: service_healthy`
  so the proxy doesn't start routing traffic before the app is actually up.
- Didn't bother replicating the rate-limit on the k8s Ingress - the task
  said not to over-engineer the bonus track, and the 429 requirement was
  really about the Compose/nginx setup.

## Quick checklist if you're grading this

Compose:
- `make up` works, two containers on one network
- nginx on :8080, app not exposed to host
- `/healthz` -> 200 + JSON with env
- flood of requests -> some 429s
- `.env` actually changes the response
- both containers show healthy in `docker ps`
- `make down` cleans everything up

Kubernetes (bonus):
- `kubectl get pods,svc,ingress` all show up and are running
- ingress routes `/healthz` correctly
- readiness/liveness probes are on the deployment
- (optional) TLS ingress terminates correctly with the self-signed cert
