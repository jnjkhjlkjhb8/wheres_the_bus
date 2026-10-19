package redistest

import (
	"bufio"
	"net"
	"reflect"
	"strings"
	"testing"
)

func TestServeConnectionStopsAfterAnIncompleteCommand(t *testing.T) {
	server, client := net.Pipe()
	t.Cleanup(func() { _ = server.Close() })
	finished := make(chan struct{})
	go func() {
		(&Endpoint{}).serveConnection(server, "get")
		close(finished)
	}()
	if _, err := client.Write([]byte("*1\r\n$3\r\nGE")); err != nil {
		t.Fatal(err)
	}
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	<-finished
}

func TestReadRESPCommandHandlesCompleteAndInterruptedFrames(t *testing.T) {
	for _, tc := range []struct {
		name, frame string
		want        []string
	}{
		{"command", "*2\r\n$3\r\nGET\r\n$5\r\nroute\r\n", []string{"GET", "route"}},
		{"empty bulk", "*1\r\n$0\r\n\r\n", []string{""}},
		{"missing array", "", nil},
		{"short array", "*\n", nil},
		{"wrong array", "+OK\r\n", nil},
		{"invalid count", "*bad\r\n", nil},
		{"missing bulk", "*1\r\n", nil},
		{"short bulk", "*1\r\n$\n", nil},
		{"wrong bulk", "*1\r\n+OK\r\n", nil},
		{"invalid length", "*1\r\n$bad\r\n", nil},
		{"truncated bulk", "*1\r\n$3\r\nGE", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := readRESPCommand(bufio.NewReader(strings.NewReader(tc.frame)))
			if tc.want == nil {
				if err == nil || got != nil {
					t.Fatalf("incomplete frame = %v, error %v", got, err)
				}
			} else if err != nil || !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("RESP = %v, error %v, want %v", got, err, tc.want)
			}
		})
	}
}
