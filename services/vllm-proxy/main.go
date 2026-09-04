// SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"sync"
	"time"

	"nvpair-shared/applog"
	"nvpair-shared/clustertrust"
	"nvpair-shared/discovery"
	"nvpair-shared/errors"
	"nvpair-shared/ipc"
	"nvpair-shared/jsonrpc"
	"nvpair-shared/noderec"
)

const (
	// vLLM default engine port
	vllmEnginePort = 8000
	// vLLM proxy default port
	vllmProxyPort = 8001
)

// Version is set at build time via -ldflags
var Version = "dev"

type aliasAddressFlags []string

func (a *aliasAddressFlags) String() string { return strings.Join(*a, ",") }
func (a *aliasAddressFlags) Set(value string) error {
	*a = append(*a, value)
	return nil
}

func main() {
	port := flag.Int("port", vllmProxyPort, "HTTP listen port (vLLM engine default 8000, proxy default 8001)")
	var aliasAddresses aliasAddressFlags
	flag.Var(&aliasAddresses, "alias-address", "optional loopback-only HTTP alias address (repeat for another loopback family)")
	ignorePersistedPort := flag.Bool("ignore-persisted-port", false, "use --port even when a persisted port exists")
	ipcPath := flag.String("ipc", "", "IPC endpoint: Unix domain socket path or Windows named pipe (default: stdin/stdout)")
	clusterDir := flag.String("cluster-dir", "", "cluster trust directory (node.crt/key + trusted pins); enables the LAN mTLS inference ingress when this node is clustered")
	showVersion := flag.Bool("version", false, "print version and exit")
	resolveLevel := applog.RegisterFlag(nil, slog.LevelInfo)
	flag.Parse()

	if *showVersion {
		fmt.Println(Version)
		os.Exit(0)
	}

	applog.Init("vllm-proxy", resolveLevel())

	var transport io.ReadWriteCloser
	if *ipcPath != "" {
		conn, err := ipc.Dial(*ipcPath)
		if err != nil {
			log.Fatalf("failed to connect to IPC endpoint %q: %v", *ipcPath, err)
		}
		transport = conn
		log.Printf("using IPC transport: %s", *ipcPath)
	} else {
		transport = newStdioTransport()
		log.Print("using stdio transport")
	}
	defer transport.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		select {
		case sig := <-sigCh:
			log.Printf("received %s, shutting down", sig)
			cancel()
		case <-ctx.Done():
		}
	}()

	persisted, hasPersisted := loadPersistedPort()
	effectivePort := chooseStartupPort(*port, *ignorePersistedPort, persisted, hasPersisted)
	if hasPersisted && !*ignorePersistedPort {
		log.Printf("restored persisted proxy port %d", persisted)
	}

	codec := jsonrpc.NewCodec(transport)
	disc := discovery.New()
	proxy := newVLLMProxy(codec, disc, effectivePort)
	for _, aliasAddress := range aliasAddresses {
		if err := proxy.setLoopbackAlias(aliasAddress); err != nil {
			log.Fatalf("invalid alias address: %v", err)
		}
	}
	proxy.mesh = clustertrust.Open(*clusterDir)

	go proxy.mesh.Watch(ctx, func(clustered bool) {
		slog.Info("cluster inference ingress switched personality", "cluster_ingress", clustered)
		proxy.dropUnpinnedPeerTransports()
	})

	if err := proxy.Run(ctx); err != nil && ctx.Err() == nil {
		log.Fatalf("proxy error: %v", err)
	}
	log.Print("shutdown complete")
}

// --- Stdio transport ---
type stdioTransport struct {
	r *os.File
	w *os.File
}

func newStdioTransport() *stdioTransport {
	return &stdioTransport{r: os.Stdin, w: os.Stdout}
}

func (t *stdioTransport) Read(p []byte) (int, error)  { return t.r.Read(p) }
func (t *stdioTransport) Write(p []byte) (int, error) { return t.w.Write(p) }
func (t *stdioTransport) Close() error                { return nil }

// --- IPC dial ---
func dialIPC(path string) (io.ReadWriteCloser, error) {
	return ipc.Dial(path)
}

// --- Persisted port ---
const persistedPortFile = "vllm-proxy-port"

func loadPersistedPort() (int, bool) {
	data, err := os.ReadFile(persistedPortFile)
	if err != nil {
		return 0, false
	}
	port, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return 0, false
	}
	return port, true
}

func chooseStartupPort(flagPort int, ignore bool, persisted int, hasPersisted bool) int {
	if hasPersisted && !ignore {
		return persisted
	}
	return flagPort
}

func persistPort(port int) {
	_ = os.WriteFile(persistedPortFile, []byte(strconv.Itoa(port)), 0644)
}

// --- VLLM Proxy ---
type vllmProxy struct {
	codec          *jsonrpc.Codec
	disc           *discovery.Discovery
	port           int
	server         *http.Server
	mesh           *clustertrust.Mesh
	mu             sync.RWMutex
	loopbackAlias  string
	clusterIngress bool
	localBackend   *url.URL
}

func newVLLMProxy(codec *jsonrpc.Codec, disc *discovery.Discovery, port int) *vllmProxy {
	return &vllmProxy{
		codec: codec,
		disc:  disc,
		port:  port,
	}
}

func (p *vllmProxy) setLoopbackAlias(addr string) error {
	u, err := url.Parse(addr)
	if err != nil {
		return err
	}
	if u.Scheme != "http" {
		return fmt.Errorf("alias address must be http, got %s", u.Scheme)
	}
	p.mu.Lock()
	p.loopbackAlias = u.Host
	p.mu.Unlock()
	return nil
}

func (p *vllmProxy) setLocalBackend(target *url.URL) {
	p.mu.Lock()
	p.localBackend = target
	p.mu.Unlock()
	persistPort(target.Port())
}

func (p *vllmProxy) localBackendTarget() *url.URL {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.localBackend
}

func (p *vllmProxy) dropUnpinnedPeerTransports() {
	// Simplified: no-op for now
}

func (p *vllmProxy) Run(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/", p.handleRequest)
	mux.HandleFunc("/health", p.handleHealth)
	mux.HandleFunc("/ready", p.handleReady)

	p.server = &http.Server{
		Addr:              ":" + strconv.Itoa(p.port),
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	persistPort(p.port)
	log.Printf("vLLM proxy listening on :%d", p.port)

	go func() {
		<-ctx.Done()
		p.server.Shutdown(context.Background())
	}()

	return p.server.ListenAndServe()
}

func (p *vllmProxy) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

func (p *vllmProxy) handleReady(w http.ResponseWriter, r *http.Request) {
	// Ready if we have a local backend
	if p.localBackendTarget() != nil {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("READY"))
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("NO_BACKEND"))
	}
}

func (p *vllmProxy) handleRequest(w http.ResponseWriter, r *http.Request) {
	target := p.localBackendTarget()
	if target == nil {
		http.Error(w, "no vLLM backend configured", http.StatusServiceUnavailable)
		return
	}

	// Clone request and forward to local vLLM engine
	r2 := r.Clone(r.Context())
	r2.URL.Scheme = target.Scheme
	r2.URL.Host = target.Host
	r2.Host = target.Host

	// Add API key header if needed
	r2.Header.Set("Authorization", "Bearer vllm-local")

	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		slog.Error("vLLM proxy error", "err", err)
		http.Error(w, "upstream error", http.StatusBadGateway)
	}
	proxy.ServeHTTP(w, r2)
}
