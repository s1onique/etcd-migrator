.PHONY: test gate fmt-check vet build clean lab-k3s-etcd-cold-import lab-k3s-etcd-cold-import-replay lab-k3s-external-etcd-cutover verify-artifact verify-replay-artifact verify-cutover-artifact

test:
	go test ./...

gate: vet fmt-check test verify-artifact verify-replay-artifact
	@echo "✓ Quality gate passed"

verify-artifact:
	@echo "Running artifact verifier self-test..."
	@bash scripts/verify_k3s_etcd_cold_import_artifact.sh --self-test

verify-replay-artifact:
	@echo "Running replay artifact verifier self-test..."
	@bash scripts/verify_k3s_etcd_cold_import_replay_artifact.sh --self-test

lab-k3s-etcd-cold-import:
	@echo "This lab requires root because k3s installs system services."
	@echo "Run: sudo bash scripts/lab_k3s_etcd_cold_import.sh"

lab-k3s-etcd-cold-import-replay:
	@echo "This lab requires root because k3s installs system services."
	@echo "Run: sudo bash scripts/lab_k3s_etcd_cold_import_replay.sh"

lab-k3s-external-etcd-cutover:
	@echo "This lab requires root because k3s installs system services."
	@echo "Run: sudo bash scripts/lab_k3s_external_etcd_cutover.sh"

verify-cutover-artifact:
	@echo "Running cutover artifact verifier self-test..."
	@bash scripts/verify_k3s_external_etcd_cutover_artifact.sh --self-test

vet:
	go vet ./...

fmt-check:
	@unformatted=$$(gofmt -l .); \
	if [[ -n "$$unformatted" ]]; then \
		echo "ERROR: gofmt required:" >&2; \
		echo "$$unformatted" >&2; \
		exit 1; \
	fi
	@echo "✓ Formatting check passed"

fmt:
	gofmt -w .

build:
	go build -o bin/etcd-migrator ./cmd/etcd-migrator

clean:
	rm -rf bin/
	rm -f /tmp/etcd-migrator-gofmt.txt
