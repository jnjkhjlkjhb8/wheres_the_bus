package redistest

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"testing"
)

type Endpoint struct {
	Address           string
	CommandStarted    chan struct{}
	ConnectionStopped chan struct{}
	listener          net.Listener
}

func Start(t *testing.T, targetCommand string) *Endpoint {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	endpoint := &Endpoint{
		Address: listener.Addr().String(), CommandStarted: make(chan struct{}),
		ConnectionStopped: make(chan struct{}), listener: listener,
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		defer func() { _ = connection.Close() }()
		reader := bufio.NewReader(connection)
		writer := bufio.NewWriter(connection)
		for {
			command, err := readRESPCommand(reader)
			if err != nil {
				return
			}
			name := strings.ToLower(command[0])
			if name == strings.ToLower(targetCommand) {
				close(endpoint.CommandStarted)
				_, _ = reader.ReadByte()
				close(endpoint.ConnectionStopped)
				return
			}
			if name == "hello" {
				_, _ = writer.WriteString("-ERR unknown command 'hello'\r\n")
			} else {
				_, _ = writer.WriteString("+OK\r\n")
			}
			if err := writer.Flush(); err != nil {
				return
			}
		}
	}()
	return endpoint
}

func readRESPCommand(reader *bufio.Reader) ([]string, error) {
	line, err := reader.ReadString('\n')
	if err != nil {
		return nil, err
	}
	if len(line) < 3 || line[0] != '*' {
		return nil, fmt.Errorf("unexpected RESP array header %q", line)
	}
	count, err := strconv.Atoi(strings.TrimSpace(line[1:]))
	if err != nil {
		return nil, err
	}
	parts := make([]string, count)
	for index := range parts {
		lengthLine, err := reader.ReadString('\n')
		if err != nil {
			return nil, err
		}
		if len(lengthLine) < 3 || lengthLine[0] != '$' {
			return nil, fmt.Errorf("unexpected RESP bulk header %q", lengthLine)
		}
		length, err := strconv.Atoi(strings.TrimSpace(lengthLine[1:]))
		if err != nil {
			return nil, err
		}
		value := make([]byte, length+2)
		if _, err := io.ReadFull(reader, value); err != nil {
			return nil, err
		}
		parts[index] = string(value[:length])
	}
	return parts, nil
}
