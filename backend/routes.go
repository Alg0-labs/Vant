package main

import "net/http"

// apiV1Prefix is the version prefix every backend route is mounted under.
// Bumping the API to a new major version means adding a new prefix here
// alongside this one, not rewriting existing handlers.
const apiV1Prefix = "/api/v1"

// newRouter mounts the versioned API surface. POST /api/v1/dictate is the
// only endpoint in this phase.
func newRouter(s *Server) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc(apiV1Prefix+"/dictate", s.handleDictate)
	return mux
}
