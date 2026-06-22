package store

import (
	"crypto/rand"
)

// NewID returns a 12-char URL-safe random identifier (NanoID-style). 12 chars
// from a 64-symbol alphabet gives ~72 bits of entropy — far more than this
// app will ever need, while staying short enough to read in logs.
//
// Alphabet matches the standard NanoID set so callers can paste IDs into any
// URL without escaping.
func NewID() string {
	const (
		alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
		size     = 12
	)
	b := make([]byte, size)
	// Each random byte selects an alphabet index by masking to 6 bits. The
	// alphabet length is exactly 64, so no rejection sampling is required.
	if _, err := rand.Read(b); err != nil {
		// crypto/rand never errors in practice on supported platforms.
		panic(err)
	}
	for i := 0; i < size; i++ {
		b[i] = alphabet[b[i]&63]
	}
	return string(b)
}
