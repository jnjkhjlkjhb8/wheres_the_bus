package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
)

func riderCertificateDirs(t *testing.T) (string, string) {
	t.Helper()
	rootKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	root := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "rider-test-root"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	rootDER, err := x509.CreateCertificate(rand.Reader, root, root, &rootKey.PublicKey, rootKey)
	if err != nil {
		t.Fatal(err)
	}
	makeLeaf := func(name string, serial int64) string {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		leaf := &x509.Certificate{SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: name}, DNSNames: []string{name}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}}
		der, err := x509.CreateCertificate(rand.Reader, leaf, root, &key.PublicKey, rootKey)
		if err != nil {
			t.Fatal(err)
		}
		keyDER, err := x509.MarshalECPrivateKey(key)
		if err != nil {
			t.Fatal(err)
		}
		dir := t.TempDir()
		for name, block := range map[string]*pem.Block{"tls.crt": {Type: "CERTIFICATE", Bytes: der}, "tls.key": {Type: "EC PRIVATE KEY", Bytes: keyDER}, "ca.crt": {Type: "CERTIFICATE", Bytes: rootDER}} {
			if err := os.WriteFile(filepath.Join(dir, name), pem.EncodeToMemory(block), 0o600); err != nil {
				t.Fatal(err)
			}
		}
		return dir
	}
	return makeLeaf("rider-api", 2), makeLeaf("api", 3)
}

func TestRiderGRPCRequiresAndAcceptsMutualTLS(t *testing.T) {
	serverDir, clientDir := riderCertificateDirs(t)
	server, err := newRiderGRPCServer(nil, nil, serverDir)
	if err != nil {
		t.Fatal(err)
	}
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		server.Stop()
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- server.Serve(lis) }()
	t.Cleanup(func() {
		server.Stop()
		_ = lis.Close()
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("gRPC serve cleanup: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Error("gRPC serve failed to stop")
		}
	})
	cfg, err := shared.MTLSConfig(clientDir, false, "rider-api")
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name        string
		certificate bool
		want        codes.Code
	}{
		{"cluster-client", true, codes.InvalidArgument},
		{"without-client-certificate", false, codes.Unavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			clientTLS := cfg.Clone()
			if !tc.certificate {
				clientTLS.Certificates = nil
			}
			conn, err := grpc.NewClient(lis.Addr().String(), grpc.WithTransportCredentials(credentials.NewTLS(clientTLS)))
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = conn.Close() }()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_, err = pb.NewFirebase_ServiceClient(conn).ListDeviceState(ctx, &pb.DeviceRequest{})
			if status.Code(err) != tc.want {
				t.Fatalf("mTLS RPC=%v, expected %s", err, tc.want)
			}
		})
	}
}
