// Package alert streams service alerts (bus, metro, TRA, THSR) out of Redis
// Pub/Sub. It holds no state of its own: the functions MQTT subscriber writes
// the alerts and this only fans them out.
package alert

import (
	pb "github.com/jnjkhjlkjhb8/wheres_the_bus/models"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/api/internal/livestream"
	"github.com/jnjkhjlkjhb8/wheres_the_bus/services/shared"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/encoding/protojson"
)

type AlertServer struct {
	pb.UnimplementedAlert_ServiceServer

	live livestream.LiveSource
}

// BusAlert streams bus service disruptions for the requested city. The city is
// interpolated into the Redis channel name, so an empty city subscribes to a
// channel that never receives messages.
func (s *AlertServer) BusAlert(in *pb.Alert_Bus_Ask, stream grpc.ServerStreamingServer[pb.Alert_Msg]) error {
	return streamAlert(s.live, shared.AlertBusAlertChannel(in.City), stream)
}

// MetroAlert streams metro alerts for the requested rail system (e.g. TRTC,
// KRTC). The system code is interpolated into the Redis channel name.
func (s *AlertServer) MetroAlert(in *pb.Alert_Metro_Ask, stream grpc.ServerStreamingServer[pb.Alert_Msg]) error {
	key := shared.AlertMetroChannel(in.System)
	return streamAlert(s.live, key, stream)
}

// TraAlert streams TRA (conventional rail) alerts. The request carries no
// parameters; all TRA alerts share one channel.
func (s *AlertServer) TraAlert(_ *pb.Alert_Ask, stream grpc.ServerStreamingServer[pb.Alert_Msg]) error {
	return streamAlert(s.live, shared.AlertTraChannel, stream)
}

// ThsrAlert streams THSR (high-speed rail) alerts. The request carries no
// parameters; all THSR alerts share one channel.
func (s *AlertServer) ThsrAlert(_ *pb.Alert_Ask, stream grpc.ServerStreamingServer[pb.Alert_Msg]) error {
	return streamAlert(s.live, shared.AlertThsrChannel, stream)
}

func streamAlert(live livestream.LiveSource, key string, stream grpc.ServerStreamingServer[pb.Alert_Msg]) error {
	return livestream.StreamLive(stream.Context(), live, livestream.LiveStreamSpec{
		Channel:  key,
		SeedKeys: []string{key},
	}, func(data []byte) error {
		var msg pb.Alert_Msg
		if err := protojson.Unmarshal(data, &msg); err != nil {
			zap.S().Warnw("decode failed",
				"component", "alert",
				"action", "stream",
				"event", "decode_failed",
				"channel", key,
				"err", err,
			)
			return nil
		}
		return stream.Send(&msg)
	})
}

// NewAlertServer wires the live source the alert streams fan out from.
func NewAlertServer(live livestream.LiveSource) *AlertServer {
	return &AlertServer{live: live}
}
