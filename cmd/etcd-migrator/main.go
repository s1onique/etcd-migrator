package main

import (
	"fmt"
	"os"

	"github.com/spbnix/etcd-migrator/internal/version"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "version" {
		fmt.Println(version.String())
		return
	}

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
