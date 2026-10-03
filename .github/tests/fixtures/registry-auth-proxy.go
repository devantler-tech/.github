// A loopback-only token fixture in front of the actual disposable OCI registry.
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
)

func main() {
	upstream, err := url.Parse("http://127.0.0.1:5000")
	if err != nil {
		panic(err)
	}
	proxy := httputil.NewSingleHostReverseProxy(upstream)
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Printf("%q %q\n", r.Method, r.URL.Path)
		if r.URL.Path == "/token" {
			user, password, ok := r.BasicAuth()
			q := r.URL.Query()
			scope := q.Get("scope")
			if r.Method != "GET" || !ok || user != "fixture" || password != "synthetic-token" ||
				q.Get("service") != "registry.test:5443" || len(q) != 2 ||
				(scope != "repository:devantler-tech/app:pull" && scope != "repository:devantler-tech/app/manifests:pull") {
				http.Error(w, "unexpected authentication request", http.StatusBadRequest)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{"token": "synthetic-bearer"})
			return
		}
		if len(r.URL.Path) < 4 || r.URL.Path[:4] != "/v2/" {
			http.NotFound(w, r)
			return
		}
		if r.Method == http.MethodGet && strings.Contains(r.URL.Path, "/manifests/") &&
			r.Header.Get("Authorization") != "Bearer synthetic-bearer" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"errors":[{"code":"DENIED"}]}`))
			return
		}
		proxy.ServeHTTP(w, r)
	})
	server := &http.Server{Addr: "127.0.0.1:5443", Handler: handler, ReadHeaderTimeout: 5e9}
	if err := server.ListenAndServeTLS(os.Args[1], os.Args[2]); err != nil {
		panic(err)
	}
}
