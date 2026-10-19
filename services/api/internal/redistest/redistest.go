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
	go endpoint.serve(targetCommand)
	return endpoint
}

func (endpoint *Endpoint) serve(targetCommand string) {
	connection, err := endpoint.listener.Accept()
	if err != nil {
		return
	}
	defer func() { _ = connection.Close() }()
	endpoint.serveConnection(connection, targetCommand)
}

func (endpoint *Endpoint) serveConnection(connection net.Conn, targetCommand string) {
	reader := bufio.NewReader(connection)
	writer := bufio.NewWriter(connection)
	for {
		command, err := readRESPCommand(reader)
		if err != nil {
			return
		}
		if !endpoint.handleCommand(reader, writer, command, targetCommand) {
			return
		}
	}
}

func (endpoint *Endpoint) handleCommand(reader *bufio.Reader, writer *bufio.Writer, command []string, targetCommand string) bool {
	name := strings.ToLower(command[0])
	if name == strings.ToLower(targetCommand) {
		close(endpoint.CommandStarted)
		_, _ = reader.ReadByte()
		close(endpoint.ConnectionStopped)
		return false
	}
	return writeRESPGreeting(writer, name) == nil
}

func writeRESPGreeting(writer *bufio.Writer, name string) error {
	if name == "hello" {
		_, _ = writer.WriteString("-ERR unknown command 'hello'\r\n")
	} else {
		_, _ = writer.WriteString("+OK\r\n")
	}
	return writer.Flush()
}

func readRESPCommand(reader *bufio.Reader) ([]string, error) {
	count, err := readRESPCount(reader, '*', "array")
	if err != nil {
		return nil, err
	}
	parts := make([]string, count)
	for index := range parts {
		value, err := readRESPBulk(reader)
		if err != nil {
			return nil, err
		}
		parts[index] = value
	}
	return parts, nil
}

func readRESPBulk(reader *bufio.Reader) (string, error) {
	length, err := readRESPCount(reader, '$', "bulk")
	if err != nil {
		return "", err
	}
	value := make([]byte, length+2)
	if _, err := io.ReadFull(reader, value); err != nil {
		return "", err
	}
	return string(value[:length]), nil
}

func readRESPCount(reader *bufio.Reader, tag byte, kind string) (int, error) {
	line, err := reader.ReadString('\n')
	if err != nil {
		return 0, err
	}
	if len(line) < 3 || line[0] != tag {
		return 0, fmt.Errorf("unexpected RESP %s header %q", kind, line)
	}
	return strconv.Atoi(strings.TrimSpace(line[1:]))
}
