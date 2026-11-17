package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
)

func main() {
	listen := flag.String("listen", "127.0.0.1:0", "loopback address to serve the bridge on")
	dataDir := flag.String("data", "", "profile directory (default: %LOCALAPPDATA%\\JiejieBox\\host)")
	selftest := flag.Bool("selftest", false, "run the built-in smoke and exit")
	testHooks := flag.Bool("allow-test-hooks", false, "enable test.runtime/test.permission (never for release)")
	flag.Parse()

	dir := *dataDir
	if dir == "" {
		base, err := os.UserCacheDir()
		if err != nil {
			base = os.TempDir()
		}
		dir = filepath.Join(base, "JiejieBox", "host")
	}
	store, err := newProfileStore(dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "profile store: %v\n", err)
		os.Exit(2)
	}
	server := newHostServer(store, defaultCore())
	server.hooks = *testHooks

	if *selftest {
		if err := runSelfTest(server); err != nil {
			fmt.Fprintf(os.Stderr, "SELFTEST FAILED: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("SELFTEST OK")
		return
	}

	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen: %v\n", err)
		os.Exit(2)
	}
	fmt.Printf("LISTEN %s\n", listener.Addr().String())
	if err := server.Serve(listener); err != nil {
		fmt.Fprintf(os.Stderr, "serve: %v\n", err)
		os.Exit(1)
	}
}
