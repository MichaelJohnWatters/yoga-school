package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"firebase.google.com/go/v4/messaging"

	"github.com/studio52/yoga-school/server/internal/api"
	"github.com/studio52/yoga-school/server/internal/auth"
	"github.com/studio52/yoga-school/server/internal/push"
	"github.com/studio52/yoga-school/server/internal/secrets"
	"github.com/studio52/yoga-school/server/internal/store"
)

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	dbPath := flag.String("db", "dev.db", "sqlite database path")
	migrate := flag.Bool("migrate", false, "apply schema.sql then exit")
	seed := flag.Bool("seed", false, "apply seed.sql after migrate")
	flag.Parse()

	ctx := context.Background()
	st, err := store.Open(ctx, *dbPath)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer st.Close()

	if *migrate {
		root := projectRoot()
		if err := st.ApplySQLFile(ctx, filepath.Join(root, "db", "schema.sql")); err != nil {
			log.Fatalf("schema: %v", err)
		}
		log.Printf("applied schema")
		if *seed {
			if err := st.SeedDev(ctx); err != nil {
				log.Fatalf("seed: %v", err)
			}
			log.Printf("applied seed")
		}
		return
	}

	app, err := auth.NewApp(ctx)
	if err != nil {
		log.Fatalf("firebase init: %v", err)
	}
	fb, err := app.Auth(ctx)
	if err != nil {
		log.Fatalf("firebase auth init: %v", err)
	}
	emu := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	if emu != "" {
		log.Printf("using Firebase Auth emulator at %s", emu)
	}

	// Wire FCM dispatch into the store. The Cloud Messaging service has no
	// emulator equivalent, so when we're running against the Auth emulator
	// we deliberately skip building the messaging client — the Notifier
	// runs in log-only mode and prints the push payloads to the server log
	// instead of trying to reach real FCM with no creds.
	var messagingClient *messaging.Client
	if emu == "" {
		mc, err := app.Messaging(ctx)
		if err != nil {
			log.Printf("messaging init failed (push disabled): %v", err)
		} else {
			messagingClient = mc
		}
	} else {
		log.Print("auth emulator active — FCM dispatch will log-only")
	}
	st.SetPushDispatcher(push.New(messagingClient, st.DB()))

	// Wire the Stripe credentials Sealer from env. Unset is fine in dev —
	// the manager settings panel refuses secret writes, no other code
	// path tries to decrypt. We DO refuse to boot if any studio already
	// has saved keys and the master is missing — that pairing means an
	// ops misconfig and silent password loss.
	sealer, err := secrets.SealerFromEnv()
	if err != nil {
		log.Fatalf("secrets: %v", err)
	}
	st.SetSealer(sealer)
	if sealer == nil {
		if n, err := st.HasEncryptedStripeKeys(ctx); err == nil && n > 0 {
			log.Fatalf("STRIPE_KEY_ENC_MASTER unset but %d studio(s) have encrypted Stripe keys — refusing to boot", n)
		}
		log.Print("STRIPE_KEY_ENC_MASTER unset — Stripe key settings disabled")
	}

	// STRIPE TODO — once Stripe is wired (see
	// internal/store/products.go header for the full checklist), add a
	// POST /stripe/webhook handler ALONGSIDE the /api/v1 router but
	// OUTSIDE the auth middleware: Stripe needs an unauthenticated POST
	// path, and the handler proves the request is real by verifying the
	// signature header against the studio's stored webhook_secret. The
	// handler should call Store.ConfirmPurchase on `payment_intent.succeeded`
	// events. Easiest place to hook it: mux at the top level so /api/v1
	// stays as it is.
	srv := &http.Server{
		Addr:              *addr,
		Handler:           api.NewServer(st, fb).Routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("listening on %s (db=%s)", *addr, *dbPath)
	log.Fatal(srv.ListenAndServe())
}

// projectRoot walks up from the binary's CWD looking for db/schema.sql.
func projectRoot() string {
	cwd, _ := os.Getwd()
	for d := cwd; d != "/" && d != ""; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, "db", "schema.sql")); err == nil {
			return d
		}
	}
	return cwd
}
