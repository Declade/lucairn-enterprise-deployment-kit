// Package testutil holds tiny test-only helpers shared across the
// dashboard's internal/* test files. Lives at internal/testutil/* so
// the test binary picks it up without exporting helpers into the
// public dashboard surface.
//
// Slice 5 fix-up r1 extracted SafeBuffer from
// internal/handlers/keys_test.go after a sibling audit_test.go added
// the same pattern inline. Future test files that need to capture
// log.SetOutput'd writes during parallel sibling-tests should import
// from here rather than rolling their own.
package testutil

import (
	"bytes"
	"sync"
)

// SafeBuffer wraps bytes.Buffer with a mutex so log.SetOutput
// targeting it doesn't race with parallel sibling-test log.Printf
// calls during the brief window before t.Cleanup restores the
// original writer.
//
// Usage:
//
//	var buf testutil.SafeBuffer
//	oldOut := log.Writer()
//	oldFlags := log.Flags()
//	log.SetOutput(&buf)
//	log.SetFlags(0)
//	t.Cleanup(func() {
//	    log.SetOutput(oldOut)
//	    log.SetFlags(oldFlags)
//	})
//	// ... test body invokes log.Printf indirectly ...
//	got := buf.String()
type SafeBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

// Write satisfies io.Writer.
func (s *SafeBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

// String returns the buffered contents.
func (s *SafeBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}
