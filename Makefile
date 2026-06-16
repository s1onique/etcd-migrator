.PHONY: test gate fmt-check vet build clean

test:
	go test ./...

gate: vet fmt-check test
	@echo "✓ Quality gate passed"

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
