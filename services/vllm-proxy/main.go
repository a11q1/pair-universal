// SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"nvpair-shared/applog"
)

// Version is set at build time via -ldflags
var Version = "dev"

func main() {
	port := flag.Int("port", 8001, "HTTP listen port (vLLM engine default 8000, proxy default 8001)")
	backendURL := flag.String("backend-url", "http://127.0.0.1:8000", "loopback vLLM OpenAI endpoint")
	backendAPIKey := flag.String("backend-api-key", "vllm-local", "API key sent to the local vLLM endpoint")
	showVersion := flag.Bool("version", false, "print version and exit")
	resolveLevel := applog.RegisterFlag(nil, slog.LevelInfo)
	flag.Parse()

	if *showVersion {
		fmt.Println(Version)
		os.Exit(0)
	}

	applog.Init("vllm-proxy", resolveLevel())

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

	target, err := parseBackendURL(*backendURL)
	if err != nil {
		log.Fatalf("invalid --backend-url: %v", err)
	}

	proxy := newVLLMProxy(*port, *backendAPIKey)
	proxy.setLocalBackend(target)

	if err := proxy.Run(ctx); err != nil && ctx.Err() == nil {
		log.Fatalf("proxy error: %v", err)
	}
	log.Print("shutdown complete")
}

// --- VLLM Proxy ---
type vllmProxy struct {
	port          int
	backendAPIKey string
	server        *http.Server
	localBackend  *url.URL
}

func newVLLMProxy(port int, backendAPIKey string) *vllmProxy {
	return &vllmProxy{
		port:          port,
		backendAPIKey: backendAPIKey,
	}
}

func (p *vllmProxy) setLocalBackend(target *url.URL) {
	p.localBackend = target
}

func parseBackendURL(raw string) (*url.URL, error) {
	target, err := url.Parse(raw)
	if err != nil {
		return nil, err
	}
	if target.Scheme != "http" && target.Scheme != "https" {
		return nil, fmt.Errorf("scheme must be http or https")
	}
	if target.Hostname() == "" || target.Port() == "" {
		return nil, fmt.Errorf("host and port are required")
	}
	host := target.Hostname()
	if host != "localhost" {
		ip := net.ParseIP(host)
		if ip == nil || !ip.IsLoopback() {
			return nil, fmt.Errorf("backend must use a loopback address")
		}
	}
	return target, nil
}

func (p *vllmProxy) localBackendTarget() *url.URL {
	return p.localBackend
}

func (p *vllmProxy) Run(ctx context.Context) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/", p.handleRequest)
	mux.HandleFunc("/health", p.handleHealth)
	mux.HandleFunc("/ready", p.handleReady)

	p.server = &http.Server{
		Addr:              "127.0.0.1:" + strconv.Itoa(p.port),
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("vLLM proxy listening on 127.0.0.1:%d", p.port)

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := p.server.Shutdown(shutdownCtx); err != nil {
			slog.Warn("vLLM proxy shutdown did not complete cleanly", "err", err)
		}
	}()

	err := p.server.ListenAndServe()
	if err == http.ErrServerClosed {
		return nil
	}
	return err
}

func (p *vllmProxy) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

func (p *vllmProxy) handleReady(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if p.backendReady(ctx) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("READY"))
	} else {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("NO_BACKEND"))
	}
}

func (p *vllmProxy) backendReady(ctx context.Context) bool {
	target := p.localBackendTarget()
	if target == nil {
		return false
	}
	healthURL := *target
	healthURL.Path = "/health"
	healthURL.RawPath = ""
	healthURL.RawQuery = ""
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, healthURL.String(), nil)
	if err != nil {
		return false
	}
	p.setBackendAuthorization(req.Header)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode >= http.StatusOK && resp.StatusCode < http.StatusMultipleChoices
}

func (p *vllmProxy) setBackendAuthorization(header http.Header) {
	if p.backendAPIKey != "" {
		header.Set("Authorization", "Bearer "+p.backendAPIKey)
	} else {
		header.Del("Authorization")
	}
}

func (p *vllmProxy) handleRequest(w http.ResponseWriter, r *http.Request) {
	target := p.localBackendTarget()
	if target == nil {
		http.Error(w, "no vLLM backend configured", http.StatusServiceUnavailable)
		return
	}

	r2 := r.Clone(r.Context())
	r2.URL.Scheme = target.Scheme
	r2.URL.Host = target.Host
	r2.Host = target.Host
	p.setBackendAuthorization(r2.Header)

	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		slog.Error("vLLM proxy error", "err", err)
		http.Error(w, "upstream error", http.StatusBadGateway)
	}
	proxy.ServeHTTP(w, r2)
}
