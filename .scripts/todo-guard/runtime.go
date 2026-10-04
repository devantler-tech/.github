package guard

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

func scopedCertificate() (tls.Certificate, []byte, error) {
	key, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		return tls.Certificate{}, nil, e
	}
	serial, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if e != nil {
		return tls.Certificate{}, nil, e
	}
	cert := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "scoped scanner supervisor"}, DNSNames: []string{"raw.githubusercontent.com", "api.github.com"}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, e := x509.CreateCertificate(rand.Reader, cert, cert, &key.PublicKey, key)
	if e != nil {
		return tls.Certificate{}, nil, e
	}
	ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	private := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})
	pair, e := tls.X509KeyPair(ca, private)
	return pair, ca, e
}
func childEnvironment(inherited []string, api, ca string) []string {
	env := []string{}
	for _, entry := range inherited {
		key, _, _ := strings.Cut(entry, "=")
		switch strings.ToUpper(key) {
		case "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "INPUT_GITHUB_URL", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR":
		default:
			env = append(env, entry)
		}
	}
	return append(env, "INPUT_GITHUB_URL="+api, "HTTPS_PROXY="+api, "REQUESTS_CA_BUNDLE="+ca, "NO_PROXY=127.0.0.1")
}

// RunChild starts the unchanged scanner exactly once and independently judges its operations.
func RunChild(ctx context.Context, g *Guard, args []string, inherited []string, out io.Writer) error {
	if len(args) == 0 {
		return errors.New("scanner command missing")
	}
	pair, ca, e := scopedCertificate()
	if e != nil {
		return errors.New("scanner certificate unavailable")
	}
	caFile, e := os.CreateTemp("", "todo-guard-ca-*.pem")
	if e != nil {
		return errors.New("scanner certificate file unavailable")
	}
	defer os.Remove(caFile.Name())
	if _, e = caFile.Write(ca); e != nil {
		_ = caFile.Close()
		return errors.New("scanner certificate file incomplete")
	}
	if e = caFile.Close(); e != nil {
		return errors.New("scanner certificate file incomplete")
	}
	g.mu.Lock()
	g.certificate = pair
	g.mu.Unlock()
	listener, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		return errors.New("scanner API listener unavailable")
	}
	server := &http.Server{Handler: g, ReadHeaderTimeout: 5 * time.Second}
	defer server.Close()
	serveErrors := make(chan error, 1)
	go func() {
		e := server.Serve(listener)
		if e != nil && e != http.ErrServerClosed {
			serveErrors <- e
		}
	}()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Env = childEnvironment(inherited, "http://"+listener.Addr().String(), caFile.Name())
	cmd.Stdout = out
	cmd.Stderr = out
	childErr := cmd.Run()
	_ = server.Close()
	select {
	case <-serveErrors:
		return errors.New("scanner API listener failed")
	default:
	}
	if e = g.Verdict(); e != nil {
		return fmt.Errorf("scanner incomplete: %s; %d confirmed close operation(s) completed; scanner was not retried", e, g.CompletedCloses())
	}
	if childErr != nil {
		return errors.New("scanner process failed; scanner was not retried")
	}
	if ctx.Err() != nil {
		return errors.New("scanner deadline exceeded")
	}
	return nil
}
