package server

import (
	"errors"
	"io/fs"
)

// staticFSOverride is set during tests to inject a synthetic asset tree. In
// production, main.go wires Options.StaticFS via the top-level embed.FS.
var staticFSOverride fs.FS

// SetEmbeddedStatic is called from package main to wire the embedded asset
// tree. Keeping the //go:embed directive in main avoids the well-known Go
// constraint that embed source files cannot reference paths above their own
// package directory.
func SetEmbeddedStatic(f fs.FS) {
	staticFSOverride = f
}

// pickStaticFS returns the supplied override (tests) or the embedded
// static/ tree wired by main.
func pickStaticFS(override fs.FS) (fs.FS, error) {
	if override != nil {
		return override, nil
	}
	if staticFSOverride != nil {
		return staticFSOverride, nil
	}
	return nil, errors.New("server: no static FS configured (main must call server.SetEmbeddedStatic)")
}
