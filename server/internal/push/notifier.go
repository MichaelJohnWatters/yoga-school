// Package push fans a notification out to a user's registered FCM tokens.
//
// The store inserts an in-app notification row inside its transaction and
// then, after commit, calls Notifier.Dispatch. The dispatch is fire-and-
// forget — failures log and (for dead tokens) prune the device_tokens row,
// but never bubble back into the caller's request lifecycle.
//
// In dev (no Firebase Cloud Messaging credentials) the client is nil and
// Dispatch logs the would-be payload instead of sending. This keeps the
// store layer agnostic and lets developers see push activity in the server
// log without setting up FCM.
package push

import (
	"context"
	"database/sql"
	"log"

	"firebase.google.com/go/v4/messaging"
)

// Notifier owns dispatching pushes. A nil receiver is a no-op so the store
// can safely call Dispatch even when push wiring is disabled.
type Notifier struct {
	client *messaging.Client // nil in dev (log-only)
	db     *sql.DB
}

func New(client *messaging.Client, db *sql.DB) *Notifier {
	return &Notifier{client: client, db: db}
}

// Dispatch hands off to a background goroutine and returns immediately.
// payloadJSON is whatever the notifications.payload column stored — the
// client opens it as JSON to know which screen to route to.
func (n *Notifier) Dispatch(userID, notifType, title, body, payloadJSON string) {
	if n == nil {
		return
	}
	go n.send(context.Background(), userID, notifType, title, body, payloadJSON)
}

func (n *Notifier) send(ctx context.Context, userID, notifType, title, body, payloadJSON string) {
	rows, err := n.db.QueryContext(ctx,
		`SELECT fcm_token FROM device_tokens WHERE user_id = ?`, userID,
	)
	if err != nil {
		log.Printf("push: lookup tokens for %s: %v", userID, err)
		return
	}
	var tokens []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			continue
		}
		tokens = append(tokens, t)
	}
	rows.Close()
	if len(tokens) == 0 {
		return
	}

	data := map[string]string{
		"type":    notifType,
		"payload": payloadJSON,
	}
	for _, tok := range tokens {
		msg := &messaging.Message{
			Token:        tok,
			Notification: &messaging.Notification{Title: title, Body: body},
			Data:         data,
		}
		if n.client == nil {
			preview := tok
			if len(preview) > 12 {
				preview = preview[:12] + "…"
			}
			log.Printf("push (log-only): user=%s type=%s token=%s title=%q",
				userID, notifType, preview, title)
			continue
		}
		if _, err := n.client.Send(ctx, msg); err != nil {
			// FCM tells us when a token is permanently unusable. Dropping
			// the row keeps future dispatches from re-trying a dead device
			// and noise-ing the log.
			if messaging.IsUnregistered(err) || messaging.IsInvalidArgument(err) {
				if _, dErr := n.db.ExecContext(ctx,
					`DELETE FROM device_tokens WHERE fcm_token = ?`, tok,
				); dErr != nil {
					log.Printf("push: prune dead token: %v", dErr)
				}
				continue
			}
			log.Printf("push: send to %s failed: %v", userID, err)
		}
	}
}
