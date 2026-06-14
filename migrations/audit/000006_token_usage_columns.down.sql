DROP INDEX IF EXISTS idx_audit_events_token_usage;
ALTER TABLE audit_events
  DROP COLUMN IF EXISTS token_api_key_hash,
  DROP COLUMN IF EXISTS token_model,
  DROP COLUMN IF EXISTS cache_creation_tokens,
  DROP COLUMN IF EXISTS cache_read_tokens,
  DROP COLUMN IF EXISTS output_tokens,
  DROP COLUMN IF EXISTS input_tokens;
