package notify

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"time"

	"firebase.google.com/go/v4/messaging"
)

// AlightCard is one reading of the tracking card, in the vocabulary both native
// builders already speak.
type AlightCard struct {
	TrackID        string
	Mode           string
	Phase          string
	VehicleLabel   string
	VehicleID      string
	BoardStation   string
	TargetStation  string
	NextStation    string
	HopCount       int32
	CurrentIndex   int32
	RemainingStops int32
	LeadStops      int32
	LineCode       string
	LineColorHex   string
	AsOf           time.Time
	// StaleAfter is how long this reading stays true without another. It becomes
	// the Live Activity's stale-date, which is how the platform says "this is
	// old" when nothing can say it for us.
	StaleAfter time.Duration
}

// CardTarget is where one card lives: a device (Android's notification) and/or
// one ActivityKit activity (iOS's Live Activity). Either may be empty.
type CardTarget struct {
	FCMToken      string
	ActivityToken string
}

type CardAlert struct {
	Title string
	Body  string
}

// LeadAlert and AlightAlert are the two crossings, worded as the local iOS path
// words them so a pushed card and a foreground card never say different things.
func LeadAlert(remaining int32, target string) CardAlert {
	return CardAlert{Title: "Ready", Body: fmt.Sprintf("再過 %d 站到 %s", remaining, target)}
}

func AlightAlert(target string) CardAlert {
	return CardAlert{Title: "Get Set", Body: "下一站 " + target}
}

type TrackPusher struct {
	fcm  Sender
	apns APNSSender
}

// NewTrackPusher returns nil when neither transport is available, so callers can
// hold a nil pusher and stop worrying about it.
func NewTrackPusher(fcm Sender, apns APNSSender) *TrackPusher {
	if fcm == nil && apns == nil {
		return nil
	}
	return &TrackPusher{fcm: fcm, apns: apns}
}

func (p *TrackPusher) PushCard(ctx context.Context, card AlightCard, target CardTarget, alert *CardAlert) error {
	if p == nil {
		return nil
	}
	var errs []error
	if p.fcm != nil && target.FCMToken != "" {
		if err := p.fcm.Send(ctx, cardMessage(target.FCMToken, card)); err != nil {
			errs = append(errs, _oops.Wrapf(err, "fcm send"))
		}
	}
	if p.apns != nil && target.ActivityToken != "" {
		payload, err := liveActivityPayload(card, alert)
		if err != nil {
			errs = append(errs, _oops.Wrapf(err, "apns payload"))
		} else if err := p.apns.SendLiveActivity(ctx, target.ActivityToken, payload); err != nil {
			errs = append(errs, _oops.Wrapf(err, "apns"))
		}
	}
	return errors.Join(errs...)
}

func cardMessage(token string, card AlightCard) *messaging.Message {
	data := map[string]string{
		"type":           _trackPushType,
		"trackId":        card.TrackID,
		"mode":           card.Mode,
		"phase":          card.Phase,
		"vehicleLabel":   card.VehicleLabel,
		"vehicleId":      card.VehicleID,
		"boardStation":   card.BoardStation,
		"targetStation":  card.TargetStation,
		"nextStation":    card.NextStation,
		"hopCount":       strconv.Itoa(int(card.HopCount)),
		"currentIndex":   strconv.Itoa(int(card.CurrentIndex)),
		"remainingStops": strconv.Itoa(int(card.RemainingStops)),
		"leadStops":      strconv.Itoa(int(card.LeadStops)),
		"lineCode":       card.LineCode,
		"lineColorHex":   card.LineColorHex,
	}
	return &messaging.Message{
		Token:   token,
		Data:    data,
		Android: &messaging.AndroidConfig{Priority: "high"},
	}
}

// _trackPushType is the discriminator the Android receiver filters on. It sits
// beside the existing "alight_vibrate" type on the same FCM path.
const _trackPushType = "alight_track"

// _cardDismissalLinger keeps a terminal card on screen before the system takes it
// away, matching the linger the local iOS path ends with: an ending has to be
// seen.
const _cardDismissalLinger = 8 * time.Second

func liveActivityPayload(card AlightCard, alert *CardAlert) ([]byte, error) {
	state := map[string]any{
		"phase":          card.Phase,
		"vehicleLabel":   card.VehicleLabel,
		"nextStation":    card.NextStation,
		"hopCount":       card.HopCount,
		"currentIndex":   card.CurrentIndex,
		"remainingStops": card.RemainingStops,
		"leadStops":      card.LeadStops,
		"walkMinutes":    0,
		"asOfUnix":       card.AsOf.Unix(),
	}
	if card.VehicleID != "" {
		state["vehicleId"] = card.VehicleID
	}
	if card.LineCode != "" {
		state["lineCode"] = card.LineCode
	}
	if card.LineColorHex != "" {
		state["lineColorHex"] = card.LineColorHex
	}

	aps := map[string]any{
		"timestamp":     card.AsOf.Unix(),
		"event":         "update",
		"content-state": state,
	}
	if cardPhaseIsLive(card.Phase) {
		aps["stale-date"] = card.AsOf.Add(card.StaleAfter).Unix()
	} else {
		aps["event"] = "end"
		aps["dismissal-date"] = card.AsOf.Add(_cardDismissalLinger).Unix()
	}
	if alert != nil {
		aps["alert"] = map[string]any{"title": alert.Title, "body": alert.Body}
	}
	return json.Marshal(map[string]any{"aps": aps})
}

func cardPhaseIsLive(phase string) bool {
	switch phase {
	case "waiting", "riding", "approaching":
		return true
	}
	return false
}
