-- 000005_accumulator_durability.up.sql
-- B2 Slice 1a (PRD prd-2026-05-29-b2-high-availability, HA-06 / WS-17):
-- make the witness claim accumulator + tombstone dedup survive restarts by
-- persisting them to postgres-veil. Mirrors the id-bridge PersistencePort
-- precedent (services/id-bridge/migrations/000004_relinkage_pending.up.sql).
--
-- Today the accumulator holds partial certificate-claim sets in memory; a
-- witness restart mid-cert-assembly LOSES the in-flight certificate = lost
-- compliance evidence. These two tables make the partial state durable so
-- Restore() on the next boot replays the raw claim protos through the
-- EXISTING assembly path. The 7-key witness signable is UNCHANGED — we
-- store the RAW veil.v1.VeilClaim proto bytes (proto.Marshal), never the
-- assembled/serialized signable, so the reconstructed signing input is
-- byte-identical to the in-memory path.

-- Pending claim sets: one row per (request_id, service_id). The raw claim
-- proto is stored verbatim as BYTEA so Restore() can proto.Unmarshal it
-- back into the exact *VeilClaim that AddClaim received. A composite PK on
-- (request_id, service_id) enforces the same one-claim-per-service dedup the
-- in-memory accumulator does (cs.services[serviceID] guard).
--
-- `seq` is a monotonic insertion-order key. The assembler builds the
-- certificate's `claim_ids` array in the order claims appear in the slice
-- (i.e. arrival order); Restore MUST replay claims in that same order so a
-- cert minted after a restart has a byte-identical `claim_ids` array — and
-- therefore byte-identical signing bytes — to the no-restart path. created_at
-- (NOW()) can tie at sub-microsecond resolution for claims in the same
-- request, so a dedicated BIGSERIAL is the reliable ordering key.
CREATE TABLE IF NOT EXISTS witness_pending_claims (
    seq          BIGSERIAL NOT NULL,
    request_id   TEXT NOT NULL,
    service_id   TEXT NOT NULL,
    claim_proto  BYTEA NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (request_id, service_id)
);

-- Tombstones: one row per completed request_id. Mirrors the in-memory
-- tombstone (accumulator.go: completed claimSet kept for tombstoneTTL) so a
-- restarted witness still rejects late-arriving claims for an already-emitted
-- certificate. expires_at lets a cleanup pass garbage-collect tombstones past
-- their TTL the same way the in-memory time.AfterFunc(tombstoneTTL, ...) does.
CREATE TABLE IF NOT EXISTS witness_tombstones (
    request_id    TEXT PRIMARY KEY,
    completed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at    TIMESTAMPTZ NOT NULL
);

-- Cheap expiry sweep + restore scan.
CREATE INDEX IF NOT EXISTS idx_witness_pending_claims_request
    ON witness_pending_claims (request_id);
CREATE INDEX IF NOT EXISTS idx_witness_tombstones_expires
    ON witness_tombstones (expires_at);

-- Least-privilege grants for the restricted veil_app role.
--
-- NOTE: the veil_app role (created in 000002_restrict_veil_role) is
-- deliberately append-only on veil_certificates (INSERT/SELECT + the
-- attestation_raw UPDATE; DELETE revoked). The accumulator tables are
-- DIFFERENT: they hold EPHEMERAL in-flight state (not the immutable signed
-- certificate), so the role needs DELETE here to remove pending rows on set
-- completion and to garbage-collect expired tombstones. This does NOT relax
-- the append-only invariant on the compliance evidence itself
-- (veil_certificates) — only on the transient pre-assembly working set.
DO $$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'veil_app') THEN
    GRANT SELECT, INSERT, DELETE ON witness_pending_claims TO veil_app;
    GRANT SELECT, INSERT, DELETE ON witness_tombstones TO veil_app;
    -- BIGSERIAL on witness_pending_claims.seq creates an implicit sequence
    -- that INSERT needs USAGE on; without it veil_app's INSERT fails with
    -- "permission denied for sequence".
    GRANT USAGE ON SEQUENCE witness_pending_claims_seq_seq TO veil_app;
  END IF;
END
$$;
