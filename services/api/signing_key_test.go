package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
)

func TestLoadSigningKeyRequiresTheConfiguredFile(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "missing.pem")
	t.Setenv("POWERSYNC_KEY_FILE", missing)
	if _, err := loadSigningKey(); err == nil {
		t.Fatal("a missing configured key was accepted; replicas would each mint their own")
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatal("loadSigningKey created the configured key instead of failing")
	}

	notPEM := filepath.Join(dir, "garbage.pem")
	if err := os.WriteFile(notPEM, []byte("not a key"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("POWERSYNC_KEY_FILE", notPEM)
	if _, err := loadSigningKey(); err == nil {
		t.Fatal("a non-PEM key file was accepted")
	}

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	good := filepath.Join(dir, "key.pem")
	if err := os.WriteFile(good, pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("POWERSYNC_KEY_FILE", good)
	loaded, err := loadSigningKey()
	if err != nil || !loaded.Equal(key) {
		t.Fatalf("loadSigningKey = %v, %v; want the file's key", loaded, err)
	}
}
