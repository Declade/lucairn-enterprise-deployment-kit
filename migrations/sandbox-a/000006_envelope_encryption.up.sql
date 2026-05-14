-- Migration: Envelope encryption for crypto-shredding
-- Each identity gets its own Data Encryption Key (DEK) wrapped by the master KEK.
-- On GDPR erasure, destroying the wrapped DEK makes all encrypted fields unrecoverable
-- even if backups contain the ciphertext.

ALTER TABLE identities ADD COLUMN wrapped_dek BYTEA;
