// Package preflight provides cutover readiness checks for etcd migration.
package preflight

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"go.etcd.io/etcd/client/v3"

	"github.com/spbnix/etcd-migrator/internal/keyrange"
	"github.com/spbnix/etcd-migrator/internal/version"
)

// ValidConflictPolicies contains the allowed conflict policy values.
var ValidConflictPolicies = []string{"fail-if-present", "allow-identical-replay"}

// ResultClassification represents the outcome of preflight checks.
type ResultClassification string

const (
	ClassificationFreshImport     ResultClassification = "fresh-import"
	ClassificationIdenticalReplay ResultClassification = "identical-replay"
	ClassificationConflict        ResultClassification = "conflict"
	ClassificationEmptySource     ResultClassification = "empty-source"
	ClassificationUnhealthySource ResultClassification = "unhealthy-source"
	ClassificationUnhealthyTarget ResultClassification = "unhealthy-target"
	ClassificationInvalidPrefix   ResultClassification = "invalid-prefix"
	ClassificationUnknown         ResultClassification = "unknown"
)

// Report holds the complete preflight check results.
type Report struct {
	// GoNoGo is true when the migration can safely proceed.
	GoNoGo bool `json:"go_no_go"`
	// Classification is the deterministic outcome classification.
	Classification ResultClassification `json:"classification"`
	// SourceEndpoint describes the source etcd endpoints.
	SourceEndpoint EndpointInfo `json:"source_endpoint"`
	// TargetEndpoint describes the target etcd endpoints.
	TargetEndpoint EndpointInfo `json:"target_endpoint"`
	// Prefix is the migration key prefix.
	Prefix string `json:"prefix"`
	// ConflictPolicy is the selected conflict policy.
	ConflictPolicy string `json:"conflict_policy"`
	// SourcePrefixKeyCount is the number of keys under prefix in source.
	SourcePrefixKeyCount int64 `json:"source_prefix_key_count"`
	// TargetPrefixKeyCount is the number of keys under prefix in target.
	TargetPrefixKeyCount int64 `json:"target_prefix_key_count"`
	// Warnings contains non-fatal issues encountered during checks.
	Warnings []string `json:"warnings,omitempty"`
	// Errors contains fatal issues that blocked classification.
	Errors []string `json:"errors,omitempty"`
	// ToolVersion is the etcd-migrator version.
	ToolVersion string `json:"tool_version"`
	// Timestamp is when the report was generated.
	Timestamp time.Time `json:"timestamp"`
}

// EndpointInfo summarizes an etcd endpoint.
type EndpointInfo struct {
	// Endpoints are the endpoint addresses.
	Endpoints []string `json:"endpoints"`
	// Healthy is true when all endpoints responded to health check.
	Healthy bool `json:"healthy"`
	// Version is the etcd server version (if available).
	Version string `json:"version,omitempty"`
	// Error is the error message if the endpoint is unhealthy.
	Error string `json:"error,omitempty"`
}

// PreflightConfig holds parameters for running preflight checks.
type PreflightConfig struct {
	SourceEndpoints []string
	TargetEndpoints []string
	Prefix          string
	ConflictPolicy  string
	DialTimeout     time.Duration
	RequestTimeout  time.Duration
}

// WithDefaults returns cfg with zero-valued fields filled in.
func (c PreflightConfig) WithDefaults() PreflightConfig {
	out := c
	if out.DialTimeout == 0 {
		out.DialTimeout = 5 * time.Second
	}
	if out.RequestTimeout == 0 {
		out.RequestTimeout = 30 * time.Second
	}
	if out.ConflictPolicy == "" {
		out.ConflictPolicy = "fail-if-present"
	}
	return out
}

// Validate returns an error if cfg is not ready to be used.
func (c PreflightConfig) Validate() error {
	if len(c.SourceEndpoints) == 0 {
		return fmt.Errorf("missing source endpoints")
	}
	if len(c.TargetEndpoints) == 0 {
		return fmt.Errorf("missing target endpoints")
	}
	if c.Prefix == "" {
		return fmt.Errorf("prefix cannot be empty")
	}
	validPolicy := false
	for _, p := range ValidConflictPolicies {
		if c.ConflictPolicy == p {
			validPolicy = true
			break
		}
	}
	if !validPolicy {
		return fmt.Errorf("invalid conflict policy %q, must be one of: fail-if-present, allow-identical-replay", c.ConflictPolicy)
	}
	return nil
}

// RunPreflight checks source and target etcd endpoints and produces a readiness report.
// RunPreflight never mutates either etcd cluster.
func RunPreflight(ctx context.Context, cfg PreflightConfig) (*Report, error) {
	cfg = cfg.WithDefaults()

	// Validate configuration first.
	if err := cfg.Validate(); err != nil {
		report := &Report{
			Prefix:         cfg.Prefix,
			ConflictPolicy: cfg.ConflictPolicy,
			ToolVersion:    version.String(),
			Timestamp:      time.Now().UTC(),
			GoNoGo:         false,
			Classification: ClassificationUnknown,
			Errors:         []string{err.Error()},
		}
		return report, nil
	}

	report := &Report{
		Prefix:         cfg.Prefix,
		ConflictPolicy: cfg.ConflictPolicy,
		ToolVersion:    version.String(),
		Timestamp:      time.Now().UTC(),
	}

	// Validate prefix early.
	rangeEnd := keyrange.PrefixRangeEndString(cfg.Prefix)
	if rangeEnd == "" {
		report.GoNoGo = false
		report.Classification = ClassificationInvalidPrefix
		report.Errors = append(report.Errors, fmt.Sprintf("prefix %q cannot be bounded for range check", cfg.Prefix))
		return report, nil
	}

	// Check source endpoint health - all endpoints must respond.
	sourceInfo, sourceErr := checkAllEndpointsHealth(ctx, cfg.SourceEndpoints, cfg.DialTimeout, cfg.RequestTimeout)
	report.SourceEndpoint = sourceInfo

	// Check target endpoint health - all endpoints must respond.
	targetInfo, targetErr := checkAllEndpointsHealth(ctx, cfg.TargetEndpoints, cfg.DialTimeout, cfg.RequestTimeout)
	report.TargetEndpoint = targetInfo

	// Propagate endpoint errors.
	if sourceErr != nil {
		report.GoNoGo = false
		report.Classification = ClassificationUnhealthySource
		report.Errors = append(report.Errors, sourceErr.Error())
		return report, nil
	}
	if targetErr != nil {
		report.GoNoGo = false
		report.Classification = ClassificationUnhealthyTarget
		report.Errors = append(report.Errors, targetErr.Error())
		return report, nil
	}

	// Fetch source KV data under prefix.
	sourceKVs, sourceCount, err := fetchPrefixKVs(ctx, cfg.SourceEndpoints, cfg.Prefix, cfg.DialTimeout, cfg.RequestTimeout)
	if err != nil {
		report.GoNoGo = false
		report.Classification = ClassificationUnknown
		report.Errors = append(report.Errors, fmt.Sprintf("fetch source keys: %v", err))
		return report, nil
	}
	report.SourcePrefixKeyCount = sourceCount

	// Fetch target KV data under prefix.
	targetKVs, targetCount, err := fetchPrefixKVs(ctx, cfg.TargetEndpoints, cfg.Prefix, cfg.DialTimeout, cfg.RequestTimeout)
	if err != nil {
		report.GoNoGo = false
		report.Classification = ClassificationUnknown
		report.Errors = append(report.Errors, fmt.Sprintf("fetch target keys: %v", err))
		return report, nil
	}
	report.TargetPrefixKeyCount = targetCount

	// Classify the result using actual KV comparison.
	report.classifyWithKVComparison(sourceKVs, targetKVs)

	return report, nil
}

// classifyWithKVComparison determines the ResultClassification based on actual KV data.
func (r *Report) classifyWithKVComparison(sourceKVs, targetKVs map[string][]byte) {
	// Empty source is a terminal condition.
	if len(sourceKVs) == 0 {
		r.GoNoGo = false
		r.Classification = ClassificationEmptySource
		return
	}

	// Source has data, target is empty - this is a fresh import.
	if len(targetKVs) == 0 {
		r.GoNoGo = true
		r.Classification = ClassificationFreshImport
		return
	}

	// Both have data - need to compare actual KV pairs.
	// Keys outside the prefix are already filtered out by fetchPrefixKVs.

	// Check for identical replay when policy allows it.
	if r.ConflictPolicy == "allow-identical-replay" {
		if compareKVs(sourceKVs, targetKVs) {
			r.GoNoGo = true
			r.Classification = ClassificationIdenticalReplay
			return
		}
	}

	// Not identical - this is a conflict.
	r.GoNoGo = false
	r.Classification = ClassificationConflict
	r.Warnings = append(r.Warnings, fmt.Sprintf(
		"target has %d keys under prefix that differ from source; use allow-identical-replay only when target exactly matches source",
		len(targetKVs)))
}

// compareKVs returns true if the two KV maps are identical.
func compareKVs(a, b map[string][]byte) bool {
	if len(a) != len(b) {
		return false
	}
	for key, aVal := range a {
		bVal, ok := b[key]
		if !ok {
			return false
		}
		if string(aVal) != string(bVal) {
			return false
		}
	}
	return true
}

// checkAllEndpointsHealth verifies that ALL endpoints are reachable and returns version info.
func checkAllEndpointsHealth(ctx context.Context, endpoints []string, dialTimeout, requestTimeout time.Duration) (EndpointInfo, error) {
	info := EndpointInfo{
		Endpoints: endpoints,
		Healthy:   true,
	}

	cli, err := clientv3.New(clientv3.Config{
		Endpoints:   endpoints,
		DialTimeout: dialTimeout,
	})
	if err != nil {
		info.Healthy = false
		info.Error = fmt.Sprintf("dial: %v", err)
		return info, fmt.Errorf("connect to endpoints: %w", err)
	}
	defer cli.Close()

	ctxTimeout, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()

	// Check ALL endpoints - all must succeed for healthy.
	var lastErr error
	var version string
	for _, ep := range endpoints {
		resp, err := cli.Status(ctxTimeout, ep)
		if err != nil {
			lastErr = err
			continue
		}
		if version == "" {
			version = resp.Version
		}
	}

	if lastErr != nil {
		info.Healthy = false
		info.Error = fmt.Sprintf("status: %v", lastErr)
		return info, fmt.Errorf("get status from endpoints: %w", lastErr)
	}

	info.Version = version
	info.Healthy = true
	return info, nil
}

// fetchPrefixKVs fetches all key/value pairs under prefix from etcd.
func fetchPrefixKVs(ctx context.Context, endpoints []string, prefix string, dialTimeout, requestTimeout time.Duration) (map[string][]byte, int64, error) {
	cli, err := clientv3.New(clientv3.Config{
		Endpoints:   endpoints,
		DialTimeout: dialTimeout,
	})
	if err != nil {
		return nil, 0, fmt.Errorf("create client: %w", err)
	}
	defer cli.Close()

	rangeEnd := keyrange.PrefixRangeEndString(prefix)
	if rangeEnd == "" {
		return nil, 0, fmt.Errorf("prefix %q cannot be bounded", prefix)
	}

	ctxTimeout, cancel := context.WithTimeout(ctx, requestTimeout)
	defer cancel()

	// Fetch all keys under prefix (limit=0 means no limit).
	resp, err := cli.Get(ctxTimeout, prefix, clientv3.WithRange(rangeEnd), clientv3.WithLimit(0))
	if err != nil {
		return nil, 0, fmt.Errorf("range prefix: %w", err)
	}

	kvs := make(map[string][]byte, len(resp.Kvs))
	for _, kv := range resp.Kvs {
		kvs[string(kv.Key)] = kv.Value
	}

	return kvs, resp.Count, nil
}

// ToJSON returns the report as indented JSON bytes.
func (r *Report) ToJSON() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}

// ToJSONCompact returns the report as compact JSON bytes.
func (r *Report) ToJSONCompact() ([]byte, error) {
	return json.Marshal(r)
}

// ToText returns a human-readable report summary.
func (r *Report) ToText() string {
	var b strings.Builder
	b.WriteString("=== etcd-migrator preflight report ===\n")
	b.WriteString(fmt.Sprintf("tool version: %s\n", r.ToolVersion))
	b.WriteString(fmt.Sprintf("timestamp:    %s\n", r.Timestamp.Format(time.RFC3339)))
	b.WriteString("\n")

	b.WriteString("--- source endpoint ---\n")
	b.WriteString(fmt.Sprintf("endpoints: %v\n", r.SourceEndpoint.Endpoints))
	if r.SourceEndpoint.Healthy {
		b.WriteString(fmt.Sprintf("healthy:   true\n"))
	} else {
		b.WriteString(fmt.Sprintf("healthy:   false\n"))
		b.WriteString(fmt.Sprintf("error:     %s\n", r.SourceEndpoint.Error))
	}
	if r.SourceEndpoint.Version != "" {
		b.WriteString(fmt.Sprintf("version:   %s\n", r.SourceEndpoint.Version))
	}
	b.WriteString("\n")

	b.WriteString("--- target endpoint ---\n")
	b.WriteString(fmt.Sprintf("endpoints: %v\n", r.TargetEndpoint.Endpoints))
	if r.TargetEndpoint.Healthy {
		b.WriteString(fmt.Sprintf("healthy:   true\n"))
	} else {
		b.WriteString(fmt.Sprintf("healthy:   false\n"))
		b.WriteString(fmt.Sprintf("error:     %s\n", r.TargetEndpoint.Error))
	}
	if r.TargetEndpoint.Version != "" {
		b.WriteString(fmt.Sprintf("version:   %s\n", r.TargetEndpoint.Version))
	}
	b.WriteString("\n")

	b.WriteString("--- migration parameters ---\n")
	b.WriteString(fmt.Sprintf("prefix:          %s\n", r.Prefix))
	b.WriteString(fmt.Sprintf("conflict-policy: %s\n", r.ConflictPolicy))
	b.WriteString("\n")

	b.WriteString("--- prefix key counts ---\n")
	b.WriteString(fmt.Sprintf("source keys: %d\n", r.SourcePrefixKeyCount))
	b.WriteString(fmt.Sprintf("target keys: %d\n", r.TargetPrefixKeyCount))
	b.WriteString("\n")

	b.WriteString("--- result ---\n")
	b.WriteString(fmt.Sprintf("go/no-go:       %v\n", r.GoNoGo))
	b.WriteString(fmt.Sprintf("classification: %s\n", r.Classification))

	if len(r.Warnings) > 0 {
		b.WriteString("\n--- warnings ---\n")
		for _, w := range r.Warnings {
			b.WriteString(fmt.Sprintf("- %s\n", w))
		}
	}

	if len(r.Errors) > 0 {
		b.WriteString("\n--- errors ---\n")
		for _, e := range r.Errors {
			b.WriteString(fmt.Sprintf("- %s\n", e))
		}
	}

	return b.String()
}
