// SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestParseBackendURLAllowsLoopback(t *testing.T) {
	for _, raw := range []string{
		"http://127.0.0.1:8000",
		"http://localhost:8000",
		"https://[::1]:8000",
	} {
		if _, err := parseBackendURL(raw); err != nil {
			t.Errorf("parseBackendURL(%q): %v", raw, err)
		}
	}
}

func TestParseBackendURLRejectsUnsafeTargets(t *testing.T) {
	for _, raw := range []string{
		"http://192.168.1.20:8000",
		"http://example.com:8000",
		"file:///tmp/vllm.sock",
		"http://127.0.0.1",
	} {
		if _, err := parseBackendURL(raw); err == nil {
			t.Errorf("parseBackendURL(%q) succeeded, want error", raw)
		}
	}
}

func TestProxyForwardsToConfiguredBackend(t *testing.T) {
	var authorization string
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authorization = r.Header.Get("Authorization")
		if r.URL.Path != "/v1/models" {
			t.Errorf("backend path = %q, want /v1/models", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"data":[{"id":"test-model"}]}`)
	}))
	defer backend.Close()

	target, err := url.Parse(backend.URL)
	if err != nil {
		t.Fatal(err)
	}
	proxy := newVLLMProxy(8001, "vllm-local")
	proxy.setLocalBackend(target)

	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8001/v1/models", nil)
	rec := httptest.NewRecorder()
	proxy.handleRequest(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if authorization != "Bearer vllm-local" {
		t.Errorf("Authorization = %q, want Bearer vllm-local", authorization)
	}
	if !strings.Contains(rec.Body.String(), "test-model") {
		t.Errorf("response body = %q, want model response", rec.Body.String())
	}
}

func TestReadyRequiresBackend(t *testing.T) {
	proxy := newVLLMProxy(8001, "vllm-local")
	req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8001/ready", nil)

	missing := httptest.NewRecorder()
	proxy.handleReady(missing, req)
	if missing.Code != http.StatusServiceUnavailable {
		t.Fatalf("without backend status = %d, want 503", missing.Code)
	}

	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" {
			t.Errorf("health path = %q, want /health", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer vllm-local" {
			t.Errorf("health Authorization = %q, want Bearer vllm-local", got)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer backend.Close()
	target, err := url.Parse(backend.URL)
	if err != nil {
		t.Fatal(err)
	}
	proxy.setLocalBackend(target)
	ready := httptest.NewRecorder()
	proxy.handleReady(ready, req)
	if ready.Code != http.StatusOK {
		t.Fatalf("with backend status = %d, want 200", ready.Code)
	}

	backend.Close()
	unavailable := httptest.NewRecorder()
	proxy.handleReady(unavailable, req)
	if unavailable.Code != http.StatusServiceUnavailable {
		t.Fatalf("with unavailable backend status = %d, want 503", unavailable.Code)
	}
}
