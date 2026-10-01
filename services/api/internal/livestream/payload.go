package livestream

import (
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func DecodePayload[T proto.Message](data []byte, msg T) (T, error) {
	if err := proto.Unmarshal(data, msg); err != nil {
		return msg, status.Errorf(codes.Internal, "decode payload: %v", err)
	}
	return msg, nil
}
