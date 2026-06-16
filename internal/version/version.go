package version

import (
	"runtime/debug"
	"strings"
)

const (
	Version   = "0.1.0"
	GitCommit = "unknown"
)

// String returns the version string in a standard format.
func String() string {
	return Version
}

// Info holds version information for debugging.
type Info struct {
	Version   string
	GitCommit string
	GoVersion string
}

// GetInfo returns version info for debugging purposes.
func GetInfo() Info {
	var ok bool
	var buildInfo *debug.BuildInfo
	buildInfo, ok = debug.ReadBuildInfo()
	if !ok {
		return Info{Version: Version, GitCommit: GitCommit, GoVersion: "unknown"}
	}

	goVersion := buildInfo.GoVersion
	for _, setting := range buildInfo.Settings {
		if setting.Key == "vcs.revision" {
			return Info{
				Version:   Version,
				GitCommit: strings.TrimPrefix(setting.Value, "gitcommit:"),
				GoVersion: goVersion,
			}
		}
	}
	return Info{Version: Version, GitCommit: GitCommit, GoVersion: goVersion}
}
