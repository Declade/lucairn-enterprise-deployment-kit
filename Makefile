.PHONY: test package customer-bundle clean

test:
	bash tests/test_lucairn_cli.sh
	bash tests/static_checks.sh

package:
	bash scripts/package-release.sh

customer-bundle:
	@test -n "$(CUSTOMER_SLUG)" || (echo "CUSTOMER_SLUG is required" >&2; exit 1)
	@test -n "$(STAGING_DIR)" || (echo "STAGING_DIR is required" >&2; exit 1)
	bin/lucairn bundle prepare --customer-slug "$(CUSTOMER_SLUG)" --staging-dir "$(STAGING_DIR)" --output "$(or $(OUTPUT_DIR),dist/customer-bundles)"

clean:
	rm -rf dist support-bundles
