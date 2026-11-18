package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
)

func main() {
	defaultPipe := ""
	if runtime.GOOS == "windows" {
		defaultPipe = `\\.\pipe\jjbox-host`
	}
	pipeName := flag.String("pipe", defaultPipe, "named pipe to serve (empty disables)")
	socketPath := flag.String("socket", "", "Unix socket to serve (macOS/Linux; empty disables)")
	listen := flag.String("listen", "", "optional loopback TCP address (empty disables; tests/debug only)")
	dataDir := flag.String("data", "", "profile directory (default: %LOCALAPPDATA%\\JiejieBox\\host)")
	selftest := flag.Bool("selftest", false, "run the built-in smoke and exit")
	testHooks := flag.Bool("allow-test-hooks", false, "enable test.runtime/test.permission (never for release)")
	parentPID := flag.Int("parent-pid", 0, "exit when this parent process exits (0 disables)")
	appExe := flag.String("app-exe", "", "Flutter executable used as the autostart target")
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
	core := defaultCore()
	core.Configure(dir)
	server := newHostServer(store, core)
	server.hooks = *testHooks
	server.appExe = *appExe

	if *selftest {
		if err := runSelfTest(server); err != nil {
			fmt.Fprintf(os.Stderr, "SELFTEST FAILED: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("SELFTEST OK")
		return
	}

	var pipeListener, tcpListener, unixListener net.Listener
	if *pipeName != "" {
		listener, err := listenJJBoxPipe(*pipeName)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pipe %s: %v\n", *pipeName, err)
			os.Exit(2)
		}
		pipeListener = listener
		fmt.Printf("LISTEN pipe:%s\n", *pipeName)
	}
	if *socketPath != "" {
		listener, err := listenJJBoxSocket(*socketPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "socket %s: %v\n", *socketPath, err)
			os.Exit(2)
		}
		unixListener = listener
		fmt.Printf("LISTEN unix:%s\n", *socketPath)
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
	if pipeListener == nil && tcpListener == nil && unixListener == nil {
		fmt.Fprintln(os.Stderr, "no transport enabled: pass --pipe, --socket and/or --listen")
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
	if unixListener != nil {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := server.Serve(unixListener); err != nil {
				fmt.Fprintf(os.Stderr, "serve unix: %v\n", err)
			}
		}()
	}
	wg.Wait()
}
