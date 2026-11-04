package ratelimit

import (
	"context"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// holdCalls starts n calls that stay inside the handler until release is
// closed, and returns once all n are running.
func holdCalls(t *testing.T, interceptor grpc.UnaryServerInterceptor, n int, release <-chan struct{}) <-chan error {
	t.Helper()
	running := make(chan struct{}, n)
	done := make(chan error, n)
	handler := func(context.Context, any) (any, error) {
		running <- struct{}{}
		<-release
		return "ok", nil
	}
	for range n {
		go func() {
			_, err := interceptor(t.Context(), nil, &grpc.UnaryServerInfo{}, handler)
			done <- err
		}()
	}
	for range n {
		<-running
	}
	return done
}

func TestInFlightUnaryInterceptorRejectsOnlyPastTheLimit(t *testing.T) {
	interceptor := InFlightUnaryInterceptor(2)
	release := make(chan struct{})
	done := holdCalls(t, interceptor, 2, release)

	_, err := interceptor(t.Context(), nil, &grpc.UnaryServerInfo{}, func(context.Context, any) (any, error) {
		t.Fatal("handler ran past the in-flight limit")
		return nil, nil
	})
	if status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("third call code = %v, want %v", status.Code(err), codes.ResourceExhausted)
	}

	close(release)
	for range 2 {
		if err := <-done; err != nil {
			t.Fatalf("call within the limit failed: %v", err)
		}
	}
}

func TestInFlightUnaryInterceptorFreesSlotWhenCallReturns(t *testing.T) {
	interceptor := InFlightUnaryInterceptor(1)
	handler := func(context.Context, any) (any, error) { return "ok", nil }
	for call := range 3 {
		got, err := interceptor(t.Context(), nil, &grpc.UnaryServerInfo{}, handler)
		if err != nil || got != "ok" {
			t.Fatalf("sequential call %d = %v, %v; slot was not freed", call, got, err)
		}
	}
}

func TestInFlightUnaryInterceptorFreesSlotWhenHandlerPanics(t *testing.T) {
	interceptor := InFlightUnaryInterceptor(1)
	func() {
		defer func() { _ = recover() }()
		_, _ = interceptor(t.Context(), nil, &grpc.UnaryServerInfo{}, func(context.Context, any) (any, error) {
			panic("handler failed")
		})
	}()
	if _, err := interceptor(t.Context(), nil, &grpc.UnaryServerInfo{}, func(context.Context, any) (any, error) {
		return "ok", nil
	}); err != nil {
		t.Fatalf("call after a panicking handler = %v; slot leaked", err)
	}
}
