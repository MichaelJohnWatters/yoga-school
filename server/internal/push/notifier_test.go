package push

import (
	"database/sql"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

// pushTestDB stands up the minimum of the device_tokens table the Notifier
// reads from. We don't want to depend on the store package here — that
// would create a layering cycle, and the notifier only needs the columns
// it reads/writes.
func pushTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:?_pragma=foreign_keys(0)")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := db.Exec(`
		CREATE TABLE device_tokens (
			id          TEXT PRIMARY KEY,
			user_id     TEXT NOT NULL,
			fcm_token   TEXT NOT NULL UNIQUE,
			platform    TEXT,
			created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
		)`); err != nil {
		t.Fatal(err)
	}
	return db
}

// settle waits long enough for the Dispatch goroutine to flush. The send
// path is short (one SELECT plus per-token logging), so 50ms is plenty.
func settle() { time.Sleep(50 * time.Millisecond) }

func TestNotifier_NilReceiverNoOp(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("nil-receiver Dispatch panicked: %v", r)
		}
	}()
	var n *Notifier
	n.Dispatch("u1", "booking_confirmed", "t", "b", `{}`)
}

func TestNotifier_LogOnlyMode_NoTokens(t *testing.T) {
	// Empty device_tokens — the goroutine should bail out cleanly.
	db := pushTestDB(t)
	n := New(nil, db)
	n.Dispatch("user-1", "booking_confirmed", "Hi", "Body", `{}`)
	settle()
	// If we got here without deadlock or panic, success.
}

func TestNotifier_LogOnlyMode_TokensRemain(t *testing.T) {
	// In log-only mode the notifier must NOT delete tokens — only the
	// real FCM send path prunes dead tokens. Inserting a token and
	// firing a dispatch should leave the row intact.
	db := pushTestDB(t)
	if _, err := db.Exec(`
		INSERT INTO device_tokens (id, user_id, fcm_token, platform)
		VALUES ('t1', 'user-1', 'fcm-tok-1', 'ios')`,
	); err != nil {
		t.Fatal(err)
	}
	n := New(nil, db)
	n.Dispatch("user-1", "class_cancelled", "Hi", "Body", `{}`)
	settle()
	var count int
	if err := db.QueryRow(
		`SELECT COUNT(*) FROM device_tokens WHERE fcm_token = 'fcm-tok-1'`,
	).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Errorf("log-only mode should not delete tokens, got %d rows", count)
	}
}
