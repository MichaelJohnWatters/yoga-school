package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/studio52/yoga-school/server/internal/api"
	"github.com/studio52/yoga-school/server/internal/auth"
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

	fb, err := auth.NewClient(ctx)
	if err != nil {
		log.Fatalf("firebase auth init: %v", err)
	}
	emu := os.Getenv("FIREBASE_AUTH_EMULATOR_HOST")
	if emu != "" {
		log.Printf("using Firebase Auth emulator at %s", emu)
	}

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
