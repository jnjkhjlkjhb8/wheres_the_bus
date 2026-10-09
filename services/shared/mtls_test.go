package shared

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type testCA struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
	pem  []byte
}

func newTestCA(t *testing.T) testCA {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test-ca"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	cert, _ := x509.ParseCertificate(der)
	return testCA{cert: cert, key: key, pem: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})}
}

// leafDir writes tls.crt, tls.key and ca.crt for a leaf signed by ca, the
// layout cert-manager mounts.
func (ca testCA) leafDir(t *testing.T, name string) string {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: name},
		DNSNames:  []string{name},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	write := func(file string, data []byte) {
		if err := os.WriteFile(filepath.Join(dir, file), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("tls.crt", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	write("tls.key", pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}))
	write("ca.crt", ca.pem)
	return dir
}

// handshake runs one TLS handshake and returns the server's verdict. In TLS
// 1.3 the server checks the client certificate after the client has finished,
// so only the server side reliably reports a rejected one.
func handshake(t *testing.T, server, client *tls.Config) error {
	t.Helper()
	lis, err := tls.Listen("tcp", "127.0.0.1:0", server)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = lis.Close() }()
	result := make(chan error, 1)
	go func() {
		conn, err := lis.Accept()
		if err != nil {
			result <- err
			return
		}
		defer func() { _ = conn.Close() }()
		_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
		result <- conn.(*tls.Conn).Handshake()
	}()
	conn, err := tls.Dial("tcp", lis.Addr().String(), client)
	if err == nil {
		_ = conn.Close()
	}
	return <-result
}

func TestMTLSRequiresAClientCertificateFromTheSameCA(t *testing.T) {
	ca := newTestCA(t)
	server, err := MTLSConfig(ca.leafDir(t, "rider-api"), true, "")
	if err != nil {
		t.Fatal(err)
	}
	client, err := MTLSConfig(ca.leafDir(t, "api"), false, "rider-api")
	if err != nil {
		t.Fatal(err)
	}
	if err := handshake(t, server, client); err != nil {
		t.Fatalf("api with a cluster certificate was refused: %v", err)
	}

	noCert := client.Clone()
	noCert.Certificates = nil
	if err := handshake(t, server, noCert); err == nil {
		t.Fatal("a client without a certificate got through")
	}

	other := newTestCA(t)
	foreign, err := MTLSConfig(other.leafDir(t, "api"), false, "rider-api")
	if err != nil {
		t.Fatal(err)
	}
	foreign.RootCAs = client.RootCAs
	if err := handshake(t, server, foreign); err == nil {
		t.Fatal("a certificate from another CA got through")
	}
}

func TestGRPCCredsAreNilOrInsecureWithoutADir(t *testing.T) {
	server, err := GRPCServerCreds("")
	if err != nil || server != nil {
		t.Fatalf("GRPCServerCreds(\"\") = %v, %v; want plaintext", server, err)
	}
	client, err := GRPCClientCreds("", "rider-api")
	if err != nil || client.Info().SecurityProtocol != "insecure" {
		t.Fatalf("GRPCClientCreds(\"\") = %v, %v; want insecure", client, err)
	}
	if _, err := GRPCServerCreds(t.TempDir()); err == nil {
		t.Fatal("an empty TLS dir was accepted")
	}
}
