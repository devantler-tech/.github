package guard

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"time"
)

func (g *guard) raw(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" || r.URL.Scheme != "https" || r.URL.Host != "raw.githubusercontent.com" || r.Host != "raw.githubusercontent.com" || r.URL.RawQuery != "" || r.URL.RawPath != "" || r.Header.Get("Authorization") != "" || r.Header.Get("Proxy-Authorization") != "" {
		g.fail(w, "unexpected language route or credential")
		return
	}
	if r.URL.Path != "/github/linguist/master/lib/linguist/languages.yml" && r.URL.Path != "/alstr/todo-to-issue-action/master/syntax.json" {
		g.fail(w, "unexpected language rule path")
		return
	}
	attempts := 1
	if !g.mutationStarted {
		attempts = 3
	}
	for attempt := 0; attempt < attempts; attempt++ {
		req, e := http.NewRequestWithContext(r.Context(), "GET", r.URL.String(), nil)
		if e != nil {
			g.fail(w, "language request invalid")
			return
		}
		p, e := g.client.Do(req)
		retryable := e != nil
		if e == nil {
			body, readErr := io.ReadAll(io.LimitReader(p.Body, (8<<20)+1))
			_ = p.Body.Close()
			if readErr == nil && p.StatusCode == 200 && len(body) > 0 && len(body) <= 8<<20 {
				writeResponse(w, response{200, p.Header.Clone(), body})
				return
			}
			retryable = readErr != nil || p.StatusCode == 429 || p.StatusCode >= 500
		}
		if !retryable || attempt+1 == attempts {
			g.fail(w, "language read incomplete")
			return
		}
		timer := time.NewTimer(time.Duration(attempt+1) * 100 * time.Millisecond)
		select {
		case <-r.Context().Done():
			timer.Stop()
			g.fail(w, "language read cancelled")
			return
		case <-timer.C:
		}
	}
}

type bufferedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c bufferedConn) Read(p []byte) (int, error) { return c.reader.Read(p) }
func (g *guard) connect(w http.ResponseWriter, r *http.Request) {
	g.mu.Lock()
	allowed := (r.Host == "raw.githubusercontent.com:443" || r.Host == "api.github.com:443") && r.URL.Host == r.Host && r.Header.Get("Authorization") == "" && r.Header.Get("Proxy-Authorization") == "" && len(g.certificate.Certificate) > 0 && g.failed == nil
	if !allowed {
		g.fail(w, "unexpected HTTPS tunnel")
		g.mu.Unlock()
		return
	}
	cert := g.certificate
	g.mu.Unlock()
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		g.mu.Lock()
		g.fail(w, "HTTPS tunnel unavailable")
		g.mu.Unlock()
		return
	}
	conn, buffer, e := hijacker.Hijack()
	if e != nil {
		g.mu.Lock()
		g.failed = errors.New("HTTPS tunnel unavailable")
		g.mu.Unlock()
		return
	}
	defer conn.Close()
	if _, e = buffer.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); e != nil {
		return
	}
	if e = buffer.Flush(); e != nil {
		return
	}
	secured := tls.Server(bufferedConn{conn, buffer.Reader}, &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	e = secured.HandshakeContext(ctx)
	cancel()
	if e != nil {
		g.mu.Lock()
		if g.failed == nil {
			g.failed = errors.New("HTTPS tunnel handshake incomplete")
		}
		g.mu.Unlock()
		return
	}
	host := strings.TrimSuffix(r.Host, ":443")
	reader := bufio.NewReader(secured)
	for {
		_ = secured.SetReadDeadline(time.Now().Add(30 * time.Second))
		req, e := http.ReadRequest(reader)
		if e != nil {
			if e != io.EOF {
				g.mu.Lock()
				if g.failed == nil {
					g.failed = errors.New("HTTPS request incomplete")
				}
				g.mu.Unlock()
			}
			return
		}
		if req.Host != host || req.URL.IsAbs() || req.Method == http.MethodConnect {
			_ = req.Body.Close()
			g.mu.Lock()
			if g.failed == nil {
				g.failed = errors.New("HTTPS request host differs")
			}
			g.mu.Unlock()
			return
		}
		req.URL.Scheme = "https"
		req.URL.Host = host
		req = req.WithContext(r.Context())
		recorder := httptest.NewRecorder()
		g.ServeHTTP(recorder, req)
		_ = req.Body.Close()
		result := recorder.Result()
		result.ContentLength = int64(recorder.Body.Len())
		_ = secured.SetWriteDeadline(time.Now().Add(30 * time.Second))
		e = result.Write(secured)
		_ = result.Body.Close()
		if e != nil {
			g.mu.Lock()
			if g.failed == nil {
				g.failed = errors.New("HTTPS result incomplete")
			}
			g.mu.Unlock()
			return
		}
		if req.Close {
			return
		}
	}
}
