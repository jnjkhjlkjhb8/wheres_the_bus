package notify

import (
	"context"
	"os"
	"strings"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"golang.org/x/oauth2/google"
)

// Sender abstracts sending one FCM message, so the dispatcher can be tested
// without a real Firebase client.
type Sender interface {
	Send(context.Context, *messaging.Message) error
}

// firebaseSender is the production Sender backed by the Firebase Admin
// messaging client.
type firebaseSender struct{ client *messaging.Client }

// Send delivers one message via Firebase Cloud Messaging, returning the client's
// error (including the unregistered-token error the dispatcher checks to prune
// dead tokens).
func (s firebaseSender) Send(ctx context.Context, message *messaging.Message) error {
	_, err := s.client.Send(ctx, message)
	return err
}

// firebaseEnabled reports whether push should be wired up: FIREBASE_ENABLED is
// true and APP_ENV is not "dev". The dev guard keeps local runs from sending real
// notifications even if the flag is left on.
func firebaseEnabled() bool {
	return strings.EqualFold(os.Getenv("FIREBASE_ENABLED"), "true") && !strings.EqualFold(os.Getenv("APP_ENV"), "dev")
}

func NewFirebaseSender(ctx context.Context) (Sender, error) {
	if !firebaseEnabled() {
		return nil, nil
	}
	projectID := strings.TrimSpace(os.Getenv("FIREBASE_PROJECT_ID"))
	if projectID == "" {
		return nil, _oops.Errorf("FIREBASE_PROJECT_ID is required when Firebase is enabled")
	}
	if _, err := google.FindDefaultCredentials(ctx, "https://www.googleapis.com/auth/firebase.messaging"); err != nil {
		return nil, _oops.Wrapf(err, "load Firebase credentials")
	}
	app, err := firebase.NewApp(ctx, &firebase.Config{ProjectID: projectID})
	if err != nil {
		return nil, _oops.Wrapf(err, "initialize Firebase Admin")
	}
	client, err := app.Messaging(ctx)
	if err != nil {
		return nil, _oops.Wrapf(err, "initialize Firebase Messaging")
	}
	return firebaseSender{client: client}, nil
}
