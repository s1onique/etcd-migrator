.PHONY: test gate fmt-check vet build clean lab-k3s-etcd-cold-import

test:
	go test ./...

gate: vet fmt-check test
	@echo "✓ Quality gate passed"

lab-k3s-etcd-cold-import:
	@echo "This lab requires root because k3s installs system services."
	@echo "Run: sudo bash scripts/lab_k3s_etcd_cold_import.sh"

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
