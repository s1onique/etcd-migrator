package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/spbnix/etcd-migrator/internal/etcdsource"
	"github.com/spbnix/etcd-migrator/internal/etcdtarget"
	"github.com/spbnix/etcd-migrator/internal/inspect"
	"github.com/spbnix/etcd-migrator/internal/version"
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "version":
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
	fmt.Println("  etcd-migrator dump    --source-endpoints ENDPOINTS --prefix PREFIX --output FILE")
	fmt.Println("  etcd-migrator load    --target-endpoints ENDPOINTS --input FILE")
	fmt.Println("  etcd-migrator inspect --input FILE")
	fmt.Println("  etcd-migrator verify  --source FILE --target FILE")
	fmt.Println("  etcd-migrator version")
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
	var allowNonEmpty bool

	fs.StringVar(&targetEndpoints, "target-endpoints", "", "comma-separated etcd endpoints (required)")
	fs.StringVar(&input, "input", "", "input JSONL file (required)")
	fs.StringVar(&prefix, "prefix", "/registry/", "key prefix to load")
	fs.IntVar(&batchSize, "batch-size", 100, "batch size for etcd writes")
	fs.DurationVar(&dialTimeout, "dial-timeout", 5*time.Second, "etcd dial timeout")
	fs.DurationVar(&requestTimeout, "request-timeout", 30*time.Second, "etcd request timeout")
	fs.BoolVar(&allowNonEmpty, "allow-non-empty", false, "allow loading into non-empty target prefix")

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
		RequireEmpty:   !allowNonEmpty,
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
