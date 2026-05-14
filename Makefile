.PHONY: test package clean

test:
	bash tests/test_lucairn_cli.sh
	bash tests/static_checks.sh

package:
	bash scripts/package-release.sh

clean:
	rm -rf dist support-bundles

