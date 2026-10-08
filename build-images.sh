#!/usr/bin/env bash
#
# Builds and tags the three images Google Cloud Marketplace expects for a classic Kubernetes
# app: backend, frontend, and the deployer.
#
# Two Marketplace-specific requirements are handled here rather than in the Dockerfiles:
#
#   1. The service-name annotation. Google requires every app image manifest to carry
#      com.googleapis.cloudmarketplace.product.service.name=services/SERVICE_NAME.
#      Annotations live on the image MANIFEST, outside the layers, so they cannot come from a
#      Dockerfile — hence --annotation on buildx here.
#
#   2. Release-track tagging. Every image is tagged BOTH with the track ("1.0") and the exact
#      version ("1.0.0"). Marketplace resolves the track to pick up patch releases.
#
# PUSHING IS THE DEFAULT, and it has to be: the service-name annotation lives on the image
# MANIFEST, and `docker buildx --load` does not carry manifest annotations into the local Docker
# image store — verified, the annotation is simply absent afterwards. Only a push writes a real
# OCI manifest with the annotation attached. Set PUSH=0 to build locally instead, e.g. to load
# images into a kind cluster, but understand that those local images are NOT annotated and are
# therefore not what Marketplace should ever receive.
#
# --provenance=false --sbom=false matter just as much. With attestations enabled, buildx pushes
# an OCI image INDEX, puts the annotation only on the child manifest, and leaves the index — the
# thing the tag actually resolves to — unannotated. Disabling them makes the tag resolve directly
# to a single annotated manifest, which is what Marketplace inspects.
set -euo pipefail

# ---- configuration ---------------------------------------------------------------------
# Assigned by Google when the Producer Portal listing was created. Taken from the listing URL:
# console.cloud.google.com/producer-portal/listing-edit/<SERVICE_NAME>?project=consiva-public
SERVICE_NAME="${SERVICE_NAME:-consiva-ai-kubernetes.endpoints.consiva-public.cloud.goog}"

# The gcr.io hostname, which is now served by Artifact Registry: gcr.io/<project>/<path> maps to
# the Artifact Registry repository literally named "gcr.io" in location "us" of that project.
# That mapping is what makes this layout legal, and it is why gcr.io is used here rather than
# us-docker.pkg.dev. Marketplace requires the app's MAIN image to sit at the root of the
# repository prefix (see §"Image declaration" in the deployer schema docs). On a native
# us-docker.pkg.dev path the prefix IS the Artifact Registry repository, and Artifact Registry
# rejects a manifest pushed there (400 Bad Request) — there is no image at a repository root.
# Under gcr.io the repository is "gcr.io" and the prefix below is an ordinary image path, so the
# main image can exist exactly where Marketplace expects it.
REGISTRY="${REGISTRY:-gcr.io/consiva-public/consiva-ai-kubernetes}"
VERSION="${VERSION:-1.0.0}"
TRACK="${TRACK:-1.0}"
PUSH="${PUSH:-1}"

ANNOTATION="com.googleapis.cloudmarketplace.product.service.name=services/${SERVICE_NAME}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ "$PUSH" = "1" ]; then
  OUTPUT_FLAG="--push"
else
  OUTPUT_FLAG="--load"
  echo "WARNING: PUSH=0 — building into the local Docker store."
  echo "         The service-name annotation will NOT survive --load. Local images are for"
  echo "         cluster testing only; never publish them."
  echo
fi

# The placeholder is gone, but an overridden SERVICE_NAME is still worth checking: a wrong value
# builds and pushes perfectly happily and is only rejected by Marketplace much later, after the
# tags are spent. Every Marketplace service name is an Endpoints name ending in .cloud.goog.
case "$SERVICE_NAME" in
  *.cloud.goog) ;;
  *)
    echo "ERROR: SERVICE_NAME '${SERVICE_NAME}' does not look like a Marketplace service name." >&2
    echo "       Expected an Endpoints name ending in .cloud.goog, e.g." >&2
    echo "       consiva-ai-kubernetes.endpoints.consiva-public.cloud.goog" >&2
    exit 1
    ;;
esac

# buildx is required: the classic builder cannot set manifest annotations.
if ! docker buildx version >/dev/null 2>&1; then
  echo "ERROR: docker buildx not available — needed for --annotation." >&2
  echo "       Alternative: build normally, then apply the annotation with" >&2
  echo "       'crane mutate <image> --annotation ${ANNOTATION}'." >&2
  exit 1
fi

# $1 = image name, EMPTY for the primary image; $2 = build context; $3 = dockerfile
build () {
  local name="$1" ctx="$2" dockerfile="$3"
  local repo="${REGISTRY}${name:+/${name}}"
  echo "==> ${repo}:${VERSION} (track ${TRACK})"
  docker buildx build \
    --annotation "${ANNOTATION}" \
    --tag "${repo}:${VERSION}" \
    --tag "${repo}:${TRACK}" \
    --file "${dockerfile}" \
    --provenance=false --sbom=false \
    ${OUTPUT_FLAG} \
    "${ctx}"
}

# The backend is the app's PRIMARY image, so it is published at the prefix itself with no name
# suffix — that is what Marketplace means by "the app's main image must be in the root of the
# repository". The frontend is an additional image and lives in its own folder beneath it.
build ""         "${REPO_ROOT}/src/backend"  "${REPO_ROOT}/src/backend/CMP.API/Dockerfile"
build "frontend" "${REPO_ROOT}/src/frontend" "${REPO_ROOT}/src/frontend/Dockerfile"

# The deployer's build context is deploy/gcp itself, because its Dockerfile copies the packaged
# chart and ./schema.yaml.
#
# The chart has to be a .tar.gz whose top-level directory is literally "chart" — see the comment
# in deployer/Dockerfile for why neither of those details is negotiable. Built here rather than
# committed so the tarball can never drift from the chart sources beside it.
CHART_TARBALL="${REPO_ROOT}/deploy/gcp/chart.tar.gz"
TEST_CHART_TARBALL="${REPO_ROOT}/deploy/gcp/apptest-chart.tar.gz"
trap 'rm -f "${CHART_TARBALL}" "${TEST_CHART_TARBALL}"' EXIT
echo "==> packaging chart -> $(basename "${CHART_TARBALL}")"
tar czf "${CHART_TARBALL}" -C "${REPO_ROOT}/deploy/gcp" chart

# The verification tester, which `mpdev /scripts/verify` overlays onto the chart above. It is
# packaged the same way and for the same reasons, and it must ALSO be a top-level "chart"
# directory: overlay_test_files.py matches test files onto production files by relative path, so
# a differently-named root would silently land beside the chart instead of inside it, and the
# tester would never be rendered.
echo "==> packaging apptest chart -> $(basename "${TEST_CHART_TARBALL}")"
tar czf "${TEST_CHART_TARBALL}" -C "${REPO_ROOT}/deploy/gcp/apptest" chart

echo "==> ${REGISTRY}/deployer:${VERSION} (track ${TRACK})"
docker buildx build \
  --annotation "${ANNOTATION}" \
  --tag "${REGISTRY}/deployer:${VERSION}" \
  --tag "${REGISTRY}/deployer:${TRACK}" \
  --file "${REPO_ROOT}/deploy/gcp/deployer/Dockerfile" \
  --provenance=false --sbom=false \
  ${OUTPUT_FLAG} \
  "${REPO_ROOT}/deploy/gcp"

echo
echo "Built$([ "$PUSH" = "1" ] && echo " and pushed" || echo " (not pushed)"):"
for ref in "${REGISTRY}" "${REGISTRY}/frontend" "${REGISTRY}/deployer"; do
  echo "  ${ref}:${VERSION}"
  echo "  ${ref}:${TRACK}"
done
echo
echo "Verify the annotation landed on a manifest with:"
echo "  docker buildx imagetools inspect ${REGISTRY}:${VERSION} --raw | grep -i service.name"
