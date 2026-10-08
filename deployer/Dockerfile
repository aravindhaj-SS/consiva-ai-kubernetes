# Google's official Helm-based deployer base image. Do not substitute another base — the
# Marketplace tooling (mpdev) expects this image's entrypoint and layout.
FROM gcr.io/cloud-marketplace-tools/k8s/deployer_helm

# The chart must arrive as a TARBALL, not as a directory. /bin/create_manifests.sh in the base
# image globs "$data/chart" for files matching *.tar.gz, extracts each into /data/extracted/<name>,
# and then renders "helm template <release> /data/extracted/<name>/chart". Two consequences, both
# load-bearing:
#   - the extension must be .tar.gz (.tgz is NOT matched by that glob), and
#   - the archive's top-level directory must be named exactly "chart".
# A plain `helm package` artefact satisfies neither: it is named <chart>-<version>.tgz and its top
# -level directory is the chart name. build-images.sh therefore creates chart.tar.gz with
# `tar czf ... -C deploy/gcp chart`.
COPY chart.tar.gz /data/chart/chart.tar.gz
COPY schema.yaml /data/schema.yaml

# Verification tester, consumed only by `mpdev /scripts/verify`. deploy_with_tests.sh extracts
# /data-test/chart/*.tar.gz and overlays it onto the production chart before rendering, so this
# archive is also a top-level "chart" directory. /data-test/schema.yaml is deliberately absent:
# overlay_test_schema.py falls back to the production schema when it is missing, and the tester
# introduces no new inputs.
COPY apptest-chart.tar.gz /data-test/chart/chart.tar.gz
