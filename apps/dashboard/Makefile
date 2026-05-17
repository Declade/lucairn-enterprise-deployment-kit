# Dashboard-app local Makefile.
#
# The repo-root Makefile (../../Makefile) owns CLI tests + packaging. This
# file owns local dashboard chores (proto regen, go test, go build).

.PHONY: proto-sync test build

# proto-sync regenerates the vendored upstream witness proto stubs.
#
# The vendored proto lives at internal/witness/witness.proto and is
# kept BYTE-COMPATIBLE with the upstream `dsa.veil.v1` schema (the
# source is `dual-sandbox-architecture/proto/veil/v1/veil.proto`). The
# vendored copy carries a CITATION header with the upstream commit SHA
# it was generated from — bump the SHA whenever this target re-runs.
#
# Prereqs (one-time on a fresh dev machine):
#   brew install protobuf
#   go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
#   go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
#   # ensure $(go env GOPATH)/bin is on PATH
proto-sync:
	protoc --proto_path=internal/witness \
	  --go_out=internal/witness/pb --go_opt=paths=source_relative \
	  --go-grpc_out=internal/witness/pb --go-grpc_opt=paths=source_relative \
	  internal/witness/witness.proto

test:
	go test ./...

build:
	go build ./...
