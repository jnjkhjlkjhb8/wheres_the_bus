package shared

import (
	"crypto/tls"
	"crypto/x509"
	"os"
	"path/filepath"

	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
)

// Service-to-service TLS (ADR-0026). cert-manager mounts each service's
// certificate as a Secret volume holding tls.crt, tls.key and ca.crt; every
// private endpoint requires a client certificate signed by that CA. An empty
// dir means plaintext, for local runs without a cluster.

// MTLSConfig builds the server (server=true) or client side of the mutual TLS
// config from dir. serverName is what a client expects in the server's
// certificate; it is ignored for the server side.
func MTLSConfig(dir string, server bool, serverName string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(filepath.Join(dir, "tls.crt"), filepath.Join(dir, "tls.key"))
	if err != nil {
		return nil, _oops.With("dir", dir).Wrapf(err, "mtls: load key pair")
	}
	caPEM, err := os.ReadFile(filepath.Join(dir, "ca.crt"))
	if err != nil {
		return nil, _oops.With("dir", dir).Wrapf(err, "mtls: read CA")
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		return nil, _oops.With("dir", dir).Errorf("mtls: CA bundle holds no certificate")
	}
	cfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
	}
	if server {
		cfg.ClientCAs = pool
		cfg.ClientAuth = tls.RequireAndVerifyClientCert
	} else {
		cfg.RootCAs = pool
		cfg.ServerName = serverName
	}
	return cfg, nil
}

// GRPCServerCreds is MTLSConfig for a gRPC server, or nil (plaintext) when dir
// is empty.
func GRPCServerCreds(dir string) (credentials.TransportCredentials, error) {
	if dir == "" {
		return nil, nil
	}
	cfg, err := MTLSConfig(dir, true, "")
	if err != nil {
		return nil, err
	}
	return credentials.NewTLS(cfg), nil
}

// GRPCClientCreds is MTLSConfig for a gRPC client, or insecure credentials
// when dir is empty.
func GRPCClientCreds(dir, serverName string) (credentials.TransportCredentials, error) {
	if dir == "" {
		return insecure.NewCredentials(), nil
	}
	cfg, err := MTLSConfig(dir, false, serverName)
	if err != nil {
		return nil, err
	}
	return credentials.NewTLS(cfg), nil
}
