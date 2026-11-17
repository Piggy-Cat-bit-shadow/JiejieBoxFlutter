package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
)

func main() {
	pipeName := flag.String("pipe", `\\.\pipe\jjbox-host`, "named pipe to serve (empty disables)")
	listen := flag.String("listen", "", "optional loopback TCP address (empty disables; tests/debug only)")
	dataDir := flag.String("data", "", "profile directory (default: %LOCALAPPDATA%\\JiejieBox\\host)")
	selftest := flag.Bool("selftest", false, "run the built-in smoke and exit")
	testHooks := flag.Bool("allow-test-hooks", false, "enable test.runtime/test.permission (never for release)")
	parentPID := flag.Int("parent-pid", 0, "exit when this parent process exits (0 disables)")
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

	var pipeListener, tcpListener net.Listener
	if *pipeName != "" {
		listener, err := listenJJBoxPipe(*pipeName)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pipe %s: %v\n", *pipeName, err)
			os.Exit(2)
		}
		pipeListener = listener
		fmt.Printf("LISTEN pipe:%s\n", *pipeName)
	}
	if *listen != "" {
		listener, err := net.Listen("tcp", *listen)
		if err != nil {
			fmt.Fprintf(os.Stderr, "listen: %v\n", err)
			os.Exit(2)
		}
		tcpListener = listener
		fmt.Printf("LISTEN tcp:%s\n", listener.Addr().String())
	}
	if pipeListener == nil && tcpListener == nil {
		fmt.Fprintln(os.Stderr, "no transport enabled: pass --pipe and/or --listen")
		os.Exit(2)
	}
	if *parentPID > 0 {
		go watchParent(*parentPID)
	}

	var wg sync.WaitGroup
	if pipeListener != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := server.serveFramed(pipeListener); err != nil {
				fmt.Fprintf(os.Stderr, "serve pipe: %v\n", err)
			}
		}()
	}
	if tcpListener != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := server.Serve(tcpListener); err != nil {
				fmt.Fprintf(os.Stderr, "serve tcp: %v\n", err)
			}
		}()
	}
	wg.Wait()
}
