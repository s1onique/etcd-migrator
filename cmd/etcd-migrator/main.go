package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/spbnix/etcd-migrator/internal/digest"
	"github.com/spbnix/etcd-migrator/internal/dump"
	"github.com/spbnix/etcd-migrator/internal/etcdsource"
	"github.com/spbnix/etcd-migrator/internal/etcdtarget"
	"github.com/spbnix/etcd-migrator/internal/inspect"
	"github.com/spbnix/etcd-migrator/internal/kine"
	"github.com/spbnix/etcd-migrator/internal/preflight"
	"github.com/spbnix/etcd-migrator/internal/version"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "--help", "-h", "help":
		printUsage()
		return
	case "version", "--version", "-v":
		fmt.Println(version.String())
		return
	case "dump":
		if err := runDump(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		return
	case "load":
		if err := runLoad(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		return
	case "inspect":
		if err := runInspect(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		return
	case "preflight":
		if err := runPreflight(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		return
	case "dump-kine-postgres":
		if err := runDumpKinePostgres(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		return
	case "compare-dump-to-target":
		if err := runCompareDumpToTarget(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "error: %v\n", err)
			os.Exit(1)
		}
		return
	default:
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Println("etcd-migrator - Offline etcd v3 API key/value migrator")
	fmt.Println("Version:", version.String())
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  etcd-migrator dump                   --source-endpoints ENDPOINTS --prefix PREFIX --output FILE")
	fmt.Println("  etcd-migrator load                   --target-endpoints ENDPOINTS --input FILE [--conflict-policy POLICY]")
	fmt.Println("  etcd-migrator inspect                --input FILE")
	fmt.Println("  etcd-migrator preflight              --source-endpoints ENDPOINTS --target-endpoints ENDPOINTS --prefix PREFIX [--output FILE]")
	fmt.Println("  etcd-migrator dump-kine-postgres     --postgres-dsn DSN --prefix PREFIX --output FILE")
	fmt.Println("  etcd-migrator compare-dump-to-target --input FILE --target-endpoints ENDPOINTS")
	fmt.Println("  etcd-migrator version")
	fmt.Println()
	fmt.Println("Load conflict policies:")
	fmt.Println("  fail-if-present        (default) refuse to write into non-empty target prefix")
	fmt.Println("  allow-identical-replay  permit load only when target exactly matches dump")
	fmt.Println()
	fmt.Println("Preflight output formats:")
	fmt.Println("  text (default)  human-readable report to stdout")
	fmt.Println("  json            machine-readable JSON to stdout or --output FILE")
}

func runDump(args []string) error {
	fs := flag.NewFlagSet("dump", flag.ContinueOnError)

	var sourceEndpoints string
	var prefix string
	var output string
	var batchSize int64
	var dialTimeout time.Duration
	var requestTimeout time.Duration

	fs.StringVar(&sourceEndpoints, "source-endpoints", "", "comma-separated etcd endpoints (required)")
	fs.StringVar(&prefix, "prefix", "/registry/", "key prefix to dump")
	fs.StringVar(&output, "output", "", "output JSONL file (required)")
	fs.Int64Var(&batchSize, "batch-size", 1000, "page size for etcd range queries")
	fs.DurationVar(&dialTimeout, "dial-timeout", 5*time.Second, "etcd dial timeout")
	fs.DurationVar(&requestTimeout, "request-timeout", 30*time.Second, "etcd request timeout per page")

	if err := fs.Parse(args); err != nil {
		return err
	}

	endpoints := strings.Split(sourceEndpoints, ",")
	endpoints = removeEmpty(endpoints)
	if len(endpoints) == 0 || endpoints[0] == "" {
		return errors.New("missing --source-endpoints")
	}

	if prefix == "" {
		return errors.New("prefix cannot be empty")
	}

	if output == "" {
		return errors.New("missing --output")
	}

	cfg := etcdsource.Config{
		Endpoints:      endpoints,
		Prefix:         prefix,
		BatchSize:      batchSize,
		DialTimeout:    dialTimeout,
		RequestTimeout: requestTimeout,
	}

	// Fail-closed: write to temp file, rename only on success
	tmpOutput := output + ".tmp"
	f, err := os.Create(tmpOutput)
	if err != nil {
		return fmt.Errorf("create output: %w", err)
	}

	// Use parent context without total dump timeout;
	// DumpPrefix applies RequestTimeout per page
	ctx := context.Background()

	stats, err := etcdsource.DumpPrefix(ctx, cfg, f)
	if closeErr := f.Close(); closeErr != nil {
		os.Remove(tmpOutput)
		return fmt.Errorf("close output: %w", closeErr)
	}
	if err != nil {
		os.Remove(tmpOutput)
		return fmt.Errorf("dump: %w", err)
	}

	// Rename temp file to final output only after successful dump
	if err := os.Rename(tmpOutput, output); err != nil {
		os.Remove(tmpOutput)
		return fmt.Errorf("rename output: %w", err)
	}

	fmt.Fprintf(os.Stderr, "count:           %d\n", stats.Count)
	fmt.Fprintf(os.Stderr, "bytes:           %d\n", stats.Bytes)
	fmt.Fprintf(os.Stderr, "prefix:          %s\n", stats.Prefix)
	fmt.Fprintf(os.Stderr, "header revision: %d\n", stats.HeaderRevision)
	fmt.Fprintf(os.Stderr, "digest:          %s\n", stats.Digest)
	return nil
}

func runDumpKinePostgres(args []string) error {
	fs := flag.NewFlagSet("dump-kine-postgres", flag.ContinueOnError)

	var postgresDSN string
	var prefix string
	var output string
	var batchSize int64
	var dialTimeout time.Duration
	var requestTimeout time.Duration

	fs.StringVar(&postgresDSN, "postgres-dsn", "", "PostgreSQL DSN (required)")
	fs.StringVar(&prefix, "prefix", "/registry/", "key prefix to dump")
	fs.StringVar(&output, "output", "", "output JSONL file (required)")
	fs.Int64Var(&batchSize, "batch-size", 1000, "page size for PostgreSQL queries")
	fs.DurationVar(&dialTimeout, "dial-timeout", 5*time.Second, "PostgreSQL dial timeout")
	fs.DurationVar(&requestTimeout, "request-timeout", 30*time.Second, "PostgreSQL request timeout")

	if err := fs.Parse(args); err != nil {
		return err
	}

	if postgresDSN == "" {
		return errors.New("missing --postgres-dsn")
	}

	if prefix == "" {
		return errors.New("prefix cannot be empty")
	}

	if output == "" {
		return errors.New("missing --output")
	}

	cfg := kine.Config{
		DSN:            postgresDSN,
		Prefix:         prefix,
		BatchSize:      int(batchSize),
		DialTimeout:    dialTimeout,
		RequestTimeout: requestTimeout,
	}

	// Fail-closed: write to temp file, rename only on success
	tmpOutput := output + ".tmp"
	f, err := os.Create(tmpOutput)
	if err != nil {
		return fmt.Errorf("create output: %w", err)
	}

	ctx := context.Background()

	stats, err := kine.DumpPostgres(ctx, cfg, f)
	if closeErr := f.Close(); closeErr != nil {
		os.Remove(tmpOutput)
		return fmt.Errorf("close output: %w", closeErr)
	}
	if err != nil {
		os.Remove(tmpOutput)
		return fmt.Errorf("dump-kine-postgres: %w", err)
	}

	// Rename temp file to final output only after successful dump
	if err := os.Rename(tmpOutput, output); err != nil {
		os.Remove(tmpOutput)
		return fmt.Errorf("rename output: %w", err)
	}

	fmt.Fprintf(os.Stderr, "count:               %d\n", stats.Count)
	fmt.Fprintf(os.Stderr, "key bytes:           %d\n", stats.KeyBytes)
	fmt.Fprintf(os.Stderr, "value bytes:         %d\n", stats.ValueBytes)
	fmt.Fprintf(os.Stderr, "total bytes:         %d\n", stats.TotalBytes)
	fmt.Fprintf(os.Stderr, "lease-bearing:       %d\n", stats.LeaseCount)
	fmt.Fprintf(os.Stderr, "create revision:     %d - %d\n", stats.MinCreateRev, stats.MaxCreateRev)
	fmt.Fprintf(os.Stderr, "mod revision:         %d - %d\n", stats.MinModRev, stats.MaxModRev)
	fmt.Fprintf(os.Stderr, "digest:              %s\n", stats.Digest)
	return nil
}

func runCompareDumpToTarget(args []string) error {
	fs := flag.NewFlagSet("compare-dump-to-target", flag.ContinueOnError)

	var input string
	var targetEndpoints string
	var dialTimeout time.Duration
	var requestTimeout time.Duration

	fs.StringVar(&input, "input", "", "input JSONL file (required)")
	fs.StringVar(&targetEndpoints, "target-endpoints", "", "comma-separated etcd target endpoints (required)")
	fs.DurationVar(&dialTimeout, "dial-timeout", 5*time.Second, "etcd dial timeout")
	fs.DurationVar(&requestTimeout, "request-timeout", 30*time.Second, "etcd request timeout")

	if err := fs.Parse(args); err != nil {
		return err
	}

	if input == "" {
		return errors.New("missing --input")
	}

	endpoints := strings.Split(targetEndpoints, ",")
	endpoints = removeEmpty(endpoints)
	if len(endpoints) == 0 || endpoints[0] == "" {
		return errors.New("missing --target-endpoints")
	}

	// Read dump file and collect records
	f, err := os.Open(input)
	if err != nil {
		return fmt.Errorf("open input: %w", err)
	}
	defer f.Close()

	records, err := dump.ReadAllRecords(f)
	if err != nil {
		return fmt.Errorf("read dump: %w", err)
	}

	// Compute digest from dump
	dumpDigest, err := digest.DigestRecords(records)
	if err != nil {
		return fmt.Errorf("compute dump digest: %w", err)
	}

	// Read records from target etcd
	targetCfg := etcdsource.Config{
		Endpoints:      endpoints,
		Prefix:         "/registry/",
		BatchSize:      1000,
		DialTimeout:    dialTimeout,
		RequestTimeout: requestTimeout,
	}

	var targetRecords []dump.Record
	ctx := context.Background()

	// Use the etcd client directly for target comparison
	client, err := etcdsource.NewClient(ctx, targetCfg)
	if err != nil {
		return fmt.Errorf("create etcd client: %w", err)
	}
	defer client.Close()

	// Read all records from target
	targetRecords, err = etcdsource.FetchAllRecords(ctx, client, targetCfg)
	if err != nil {
		return fmt.Errorf("fetch target records: %w", err)
	}

	// Compute digest from target
	targetDigest, err := digest.DigestRecords(targetRecords)
	if err != nil {
		return fmt.Errorf("compute target digest: %w", err)
	}

	// Build key sets for comparison
	dumpKeys := make(map[string]bool)
	for _, rec := range records {
		key, _ := rec.DecodeKey()
		dumpKeys[string(key)] = true
	}

	targetKeys := make(map[string]bool)
	for _, rec := range targetRecords {
		key, _ := rec.DecodeKey()
		targetKeys[string(key)] = true
	}

	// Find differences
	var missingInTarget []string
	var extraInTarget []string

	for key := range dumpKeys {
		if !targetKeys[key] {
			missingInTarget = append(missingInTarget, key)
		}
	}

	for key := range targetKeys {
		if !dumpKeys[key] {
			extraInTarget = append(extraInTarget, key)
		}
	}

	// Output comparison report
	fmt.Printf("=== Compare Dump to Target ===\n")
	fmt.Printf("dump record count:   %d\n", len(records))
	fmt.Printf("target record count: %d\n", len(targetRecords))
	fmt.Printf("dump digest:         %s\n", dumpDigest)
	fmt.Printf("target digest:       %s\n", targetDigest)

	if dumpDigest == targetDigest {
		fmt.Printf("status:              SUCCESS (digests match)\n")
	} else {
		fmt.Printf("status:              FAILED (digests do not match)\n")
	}

	if len(missingInTarget) > 0 {
		fmt.Printf("\nmissing in target (%d):\n", len(missingInTarget))
		for _, key := range missingInTarget {
			fmt.Printf("  %s\n", key)
		}
	}

	if len(extraInTarget) > 0 {
		fmt.Printf("\nextra in target (%d):\n", len(extraInTarget))
		for _, key := range extraInTarget {
			fmt.Printf("  %s\n", key)
		}
	}

	if dumpDigest != targetDigest {
		return errors.New("dump and target digests do not match")
	}

	return nil
}

func removeEmpty(ss []string) []string {
	var out []string
	for _, s := range ss {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

func runLoad(args []string) error {
	fs := flag.NewFlagSet("load", flag.ContinueOnError)

	var targetEndpoints string
	var input string
	var prefix string
	var batchSize int
	var dialTimeout time.Duration
	var requestTimeout time.Duration
	var conflictPolicy string

	fs.StringVar(&targetEndpoints, "target-endpoints", "", "comma-separated etcd endpoints (required)")
	fs.StringVar(&input, "input", "", "input JSONL file (required)")
	fs.StringVar(&prefix, "prefix", "/registry/", "key prefix to load")
	fs.IntVar(&batchSize, "batch-size", 100, "batch size for etcd writes")
	fs.DurationVar(&dialTimeout, "dial-timeout", 5*time.Second, "etcd dial timeout")
	fs.DurationVar(&requestTimeout, "request-timeout", 30*time.Second, "etcd request timeout")
	fs.StringVar(&conflictPolicy, "conflict-policy", "fail-if-present",
		"conflict policy: fail-if-present or allow-identical-replay")

	if err := fs.Parse(args); err != nil {
		return err
	}

	endpoints := strings.Split(targetEndpoints, ",")
	endpoints = removeEmpty(endpoints)
	if len(endpoints) == 0 || endpoints[0] == "" {
		return errors.New("missing --target-endpoints")
	}

	if input == "" {
		return errors.New("missing --input")
	}

	f, err := os.Open(input)
	if err != nil {
		return fmt.Errorf("open input: %w", err)
	}
	defer f.Close()

	cfg := etcdtarget.Config{
		Endpoints:      endpoints,
		Prefix:         prefix,
		BatchSize:      batchSize,
		DialTimeout:    dialTimeout,
		RequestTimeout: requestTimeout,
		ConflictPolicy: etcdtarget.ConflictPolicy(conflictPolicy),
	}

	ctx := context.Background()
	stats, err := etcdtarget.LoadDump(ctx, cfg, f)
	if err != nil {
		return fmt.Errorf("load: %w", err)
	}

	fmt.Fprintf(os.Stderr, "count:  %d\n", stats.Count)
	fmt.Fprintf(os.Stderr, "bytes:  %d\n", stats.Bytes)
	fmt.Fprintf(os.Stderr, "prefix: %s\n", stats.Prefix)
	fmt.Fprintf(os.Stderr, "digest: %s\n", stats.Digest)
	return nil
}

func runInspect(args []string) error {
	fs := flag.NewFlagSet("inspect", flag.ContinueOnError)

	var input string

	fs.StringVar(&input, "input", "", "input JSONL file (required)")

	if err := fs.Parse(args); err != nil {
		return err
	}

	if input == "" {
		return errors.New("missing --input")
	}

	f, err := os.Open(input)
	if err != nil {
		return fmt.Errorf("open input: %w", err)
	}
	defer f.Close()

	stats, err := inspect.InspectDump(f)
	if err != nil {
		return fmt.Errorf("inspect: %w", err)
	}

	// Print report to stdout
	fmt.Printf("records:               %d\n", stats.Count)
	fmt.Printf("key bytes:             %d\n", stats.KeyBytes)
	fmt.Printf("value bytes:           %d\n", stats.ValueBytes)
	fmt.Printf("total bytes:           %d\n", stats.TotalBytes)
	fmt.Printf("lease-bearing records: %d\n", stats.LeaseCount)
	fmt.Printf("create revision range: %d - %d\n", stats.MinCreateRevision, stats.MaxCreateRevision)
	fmt.Printf("mod revision range:    %d - %d\n", stats.MinModRevision, stats.MaxModRevision)
	fmt.Printf("digest:                %s\n", stats.Digest)

	// Warn if leases are present
	if stats.LeaseCount > 0 {
		fmt.Fprintf(os.Stderr, "warning: %d records have lease IDs recorded; leases are not restored by load\n", stats.LeaseCount)
	}

	return nil
}

func runPreflight(args []string) error {
	fs := flag.NewFlagSet("preflight", flag.ContinueOnError)

	var sourceEndpoints string
	var targetEndpoints string
	var prefix string
	var conflictPolicy string
	var output string
	var format string
	var dialTimeout time.Duration
	var requestTimeout time.Duration

	fs.StringVar(&sourceEndpoints, "source-endpoints", "", "comma-separated etcd source endpoints (required)")
	fs.StringVar(&targetEndpoints, "target-endpoints", "", "comma-separated etcd target endpoints (required)")
	fs.StringVar(&prefix, "prefix", "/registry/", "key prefix to check")
	fs.StringVar(&conflictPolicy, "conflict-policy", "fail-if-present",
		"conflict policy: fail-if-present or allow-identical-replay")
	fs.StringVar(&output, "output", "", "output file for JSON report (optional, implies --format=json)")
	fs.StringVar(&format, "format", "text", "output format: text or json")
	fs.DurationVar(&dialTimeout, "dial-timeout", 5*time.Second, "etcd dial timeout")
	fs.DurationVar(&requestTimeout, "request-timeout", 30*time.Second, "etcd request timeout")

	if err := fs.Parse(args); err != nil {
		return err
	}

	// --output implies JSON format
	if output != "" {
		format = "json"
	}

	// Fail-closed on unknown format
	switch format {
	case "text", "json":
		// valid
	default:
		return fmt.Errorf("invalid --format %q, must be 'text' or 'json'", format)
	}

	sourceEPs := strings.Split(sourceEndpoints, ",")
	sourceEPs = removeEmpty(sourceEPs)
	if len(sourceEPs) == 0 || sourceEPs[0] == "" {
		return errors.New("missing --source-endpoints")
	}

	targetEPs := strings.Split(targetEndpoints, ",")
	targetEPs = removeEmpty(targetEPs)
	if len(targetEPs) == 0 || targetEPs[0] == "" {
		return errors.New("missing --target-endpoints")
	}

	cfg := preflight.PreflightConfig{
		SourceEndpoints: sourceEPs,
		TargetEndpoints: targetEPs,
		Prefix:          prefix,
		ConflictPolicy:  conflictPolicy,
		DialTimeout:     dialTimeout,
		RequestTimeout:  requestTimeout,
	}

	ctx := context.Background()
	report, err := preflight.RunPreflight(ctx, cfg)
	if err != nil {
		return fmt.Errorf("preflight: %w", err)
	}

	// Output the report.
	var outputBytes []byte
	switch format {
	case "json":
		outputBytes, err = report.ToJSON()
		if err != nil {
			return fmt.Errorf("format json: %w", err)
		}
	default: // text
		outputBytes = []byte(report.ToText())
	}

	// Write to file or stdout.
	if output != "" {
		if err := os.WriteFile(output, outputBytes, 0644); err != nil {
			return fmt.Errorf("write output: %w", err)
		}
		fmt.Fprintf(os.Stderr, "report written to %s\n", output)
	} else {
		fmt.Print(string(outputBytes))
	}

	return nil
}
