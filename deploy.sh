#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# WebGoat – JFrog deploy helper.
#
# Four distinct workflows:
#   maven           – build & deploy the jar with `jf mvn` (no Docker)
#   gradle          – build & deploy the jar with `jf gradle` (no Docker)
#   maven-docker    – maven build  + docker image  -> Artifactory + build-info
#   gradle-docker   – gradle build + docker image  -> Artifactory + build-info
#
# Usage:
#   ./deploy.sh maven
#   ./deploy.sh gradle
#   ./deploy.sh maven-docker
#   ./deploy.sh gradle-docker
#
# Legacy aliases (preserved for back-compat with earlier callers):
#   ./deploy.sh base        -> maven
#   ./deploy.sh dockerized  -> maven-docker
# -----------------------------------------------------------------------------

set -euo pipefail

# Shared configuration ---------------------------------------------------------
PROJECTKEY="cg-lab"
JF_PLAT="psazuse.jfrog.io"
DOCKER_REPO="cg-lab-docker"

timestamp() { date +%F_%T | tr ':' '-'; }

# -----------------------------------------------------------------------------
# 1) Maven – build & deploy jar only
# -----------------------------------------------------------------------------
callMaven()
{
    TIMESTAMP=$(timestamp)
    BUILDNAME="cg-mvn-base-webgoat"

    echo "[maven] Script executed from: ${PWD} at ${TIMESTAMP}"
    echo "[maven] Build: ${BUILDNAME}#${TIMESTAMP} project=${PROJECTKEY}"

    jf mvn clean install -DskipTests \
        --build-name "${BUILDNAME}" \
        --build-number "${TIMESTAMP}" \
        --project "${PROJECTKEY}"

    jf mvn deploy -DskipTests \
        --build-name "${BUILDNAME}" \
        --build-number "${TIMESTAMP}" \
        --project "${PROJECTKEY}"

    jf rt bce "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"
    jf rt bag "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"
    jf rt bp  "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"
}

# -----------------------------------------------------------------------------
# 2) Gradle – build & deploy jar only
#    Uses .jfrog/projects/gradle.yaml for resolve/deploy configuration.
# -----------------------------------------------------------------------------
callGradle()
{
    TIMESTAMP=$(timestamp)
    BUILDNAME="cg-gradle-base-webgoat"

    echo "[gradle] Script executed from: ${PWD} at ${TIMESTAMP}"
    echo "[gradle] Build: ${BUILDNAME}#${TIMESTAMP} project=${PROJECTKEY}"

    jf gradle clean bootJar \
        --build-name "${BUILDNAME}" \
        --build-number "${TIMESTAMP}" \
        --project "${PROJECTKEY}"

    jf gradle artifactoryPublish \
        --build-name "${BUILDNAME}" \
        --build-number "${TIMESTAMP}" \
        --project "${PROJECTKEY}"

    jf rt bce "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"
    jf rt bag "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"
    jf rt bp  "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"
}

# -----------------------------------------------------------------------------
# 3) Maven + Docker – build jar with maven, package as docker image, deploy both
# -----------------------------------------------------------------------------
callMavenDocker()
{
    TIMESTAMP=$(timestamp)
    BUILDNAME="cg-mvn-docker-webgoat"
    IMAGE="${JF_PLAT}/${DOCKER_REPO}/${BUILDNAME}"

    echo "[maven-docker] Script executed from: ${PWD} at ${TIMESTAMP}"
    echo "[maven-docker] Build: ${BUILDNAME}#${TIMESTAMP} project=${PROJECTKEY} image=${IMAGE}:${TIMESTAMP}"

    # Build the jar into target/ via maven – attach maven module to build-info.
    jf mvn clean install -DskipTests \
        --build-name "${BUILDNAME}" \
        --build-number "${TIMESTAMP}" \
        --project "${PROJECTKEY}"

    jf rt bce "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"
    jf rt bag "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"

    # Build & push docker image. JAR_DIR defaults to target/ so no build-arg needed.
    docker image build -f ./Dockerfile \
        -t "${IMAGE}:${TIMESTAMP}" \
        --metadata-file ./metadata.json \
        --push .

    IMAGE_MOD="$(jq -r '."containerimage.digest"' metadata.json)"
    echo "[maven-docker] Image digest: ${IMAGE_MOD}"
    echo "${IMAGE}:${TIMESTAMP}@${IMAGE_MOD}" > imagefile.json

    # Attach docker module to the same build-info and publish.
    jf rt bdc "${DOCKER_REPO}" \
        --image-file imagefile.json \
        --build-name "${BUILDNAME}" \
        --build-number "${TIMESTAMP}" \
        --project "${PROJECTKEY}"

    jf rt bp "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"
}

# -----------------------------------------------------------------------------
# 4) Gradle + Docker – build jar with gradle, package as docker image, deploy both
# -----------------------------------------------------------------------------
callGradleDocker()
{
    TIMESTAMP=$(timestamp)
    BUILDNAME="cg-gradle-docker-webgoat"
    IMAGE="${JF_PLAT}/${DOCKER_REPO}/${BUILDNAME}"

    echo "[gradle-docker] Script executed from: ${PWD} at ${TIMESTAMP}"
    echo "[gradle-docker] Build: ${BUILDNAME}#${TIMESTAMP} project=${PROJECTKEY} image=${IMAGE}:${TIMESTAMP}"

    # Build the jar into build/libs/ via gradle – attach gradle module to build-info.
    jf gradle clean bootJar \
        --build-name "${BUILDNAME}" \
        --build-number "${TIMESTAMP}" \
        --project "${PROJECTKEY}"

    jf gradle artifactoryPublish \
        --build-name "${BUILDNAME}" \
        --build-number "${TIMESTAMP}" \
        --project "${PROJECTKEY}"

    jf rt bce "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"
    jf rt bag "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"

    # Build & push docker image – point at gradle's output dir via build-arg.
    docker image build -f ./Dockerfile \
        --build-arg JAR_DIR=build/libs \
        -t "${IMAGE}:${TIMESTAMP}" \
        --metadata-file ./metadata.json \
        --push .

    IMAGE_MOD="$(jq -r '."containerimage.digest"' metadata.json)"
    echo "[gradle-docker] Image digest: ${IMAGE_MOD}"
    echo "${IMAGE}:${TIMESTAMP}@${IMAGE_MOD}" > imagefile.json

    # Attach docker module to the same build-info and publish.
    jf rt bdc "${DOCKER_REPO}" \
        --image-file imagefile.json \
        --build-name "${BUILDNAME}" \
        --build-number "${TIMESTAMP}" \
        --project "${PROJECTKEY}"

    jf rt bp "${BUILDNAME}" "${TIMESTAMP}" --project "${PROJECTKEY}"
}

usage()
{
    cat <<EOF
Usage: $0 <workflow>

Workflows:
  maven           Build & deploy jar via 'jf mvn'
  gradle          Build & deploy jar via 'jf gradle'
  maven-docker    Build with maven  + docker image -> Artifactory
  gradle-docker   Build with gradle + docker image -> Artifactory

Legacy aliases:
  base            -> maven
  dockerized      -> maven-docker
EOF
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
echo "Script was called with $*"

case "${1:-}" in
    maven|base)
        callMaven
        ;;
    gradle)
        callGradle
        ;;
    maven-docker|dockerized)
        callMavenDocker
        ;;
    gradle-docker)
        callGradleDocker
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        echo "Unknown workflow: $1" >&2
        usage
        exit 1
        ;;
esac
