.PHONY: help bootstrap plan apply destroy verify grafana jaeger prometheus load

help:
	@echo "Observability Stack — common commands"
	@echo ""
	@echo "  make bootstrap   one-time: create S3 + DynamoDB backend"
	@echo "  make plan        terraform plan"
	@echo "  make apply       terraform apply (creates VPC + EKS + helm releases)"
	@echo "  make destroy     terraform destroy (everything)"
	@echo "  make verify      check the cluster is healthy"
	@echo ""
	@echo "  make grafana     port-forward Grafana to http://localhost:8080"
	@echo "  make jaeger      port-forward Jaeger  to http://localhost:16686"
	@echo "  make prometheus  port-forward Prometheus UI to http://localhost:9090"
	@echo ""
	@echo "  make load        start a load generator hitting the demo frontend"
	@echo "  make build-apps  build all demo app docker images"

bootstrap:
	bash scripts/bootstrap-state.sh

plan:
	cd terraform && terraform plan -out=tfplan

apply:
	cd terraform && terraform apply -auto-approve tfplan

deploy:
	bash scripts/deploy.sh

destroy:
	bash scripts/destroy.sh

verify:
	bash scripts/verify.sh

grafana:
	@echo "Grafana: http://localhost:8080  (user: admin)"
	@echo "Password: $$(cd terraform && terraform output -raw grafana_admin_password)"
	kubectl -n observability port-forward svc/observability-stack-grafana 8080:80

jaeger:
	@echo "Jaeger UI: http://localhost:16686"
	kubectl -n observability port-forward svc/observability-stack-jaeger-query 16686:16686

prometheus:
	@echo "Prometheus UI: http://localhost:9090"
	kubectl -n observability port-forward svc/observability-stack-kube-prometheus-prometheus 9090:9090

loki:
	@echo "Loki ready: http://localhost:3100/ready"
	kubectl -n observability port-forward svc/observability-stack-loki 3100:3100

load:
	@echo "Generating load against demo frontend... (Ctrl-C to stop)"
	kubectl -n demo-apps run loadgen --rm -it --image=curlimages/curl:8.7.1 \
	  --restart=Never --image-pull-policy=IfNotPresent -- /bin/sh -c \
	  'while true; do \
	     curl -s http://frontend/api/items;     echo; \
	     curl -s http://frontend/api/checkout;  echo; \
	     curl -s http://frontend/slow;          echo; \
	     curl -s http://frontend/error 2>/dev/null; \
	     sleep 0.2; \
	   done'

build-apps:
	@for svc in frontend backend cart checkout; do \
	  echo "==> Building $$svc"; \
	  ( cd apps/$$svc && docker build -t obs-demo/$$svc:latest . ); \
	done
