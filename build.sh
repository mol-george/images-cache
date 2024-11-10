#!/usr/bin/env bash

set -euo pipefail

# Define OSes and architectures
oses=("linux")
arches=("amd64" "arm64")
platforms=()
for os in "${oses[@]}"; do
  for arch in "${arches[@]}"; do
    platforms+=("${os}/${arch}")
  done
done

temp_files=()
cleanup() {
  if [[ ${#temp_files[@]} -gt 0 ]]; then
    rm -f "${temp_files[@]}"
  fi
}
trap cleanup EXIT

check_env_vars() {
  for var in AWS_REGION REGISTRY UPSTREAM_IMAGES_TAGS; do
    : "${!var:?Need to set $var}"
  done
}

docker_login() {
  echo "Logging into Docker registry..."
  if ! aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${REGISTRY}"; then
    echo "Error: Docker login failed."
    exit 1
  fi
}

initialize_docker_buildx() {
  echo "Initializing Docker Buildx..."
  local builder_name="multiarch-builder"

  if ! docker buildx inspect "${builder_name}" >/dev/null 2>&1; then
    docker buildx create --name "${builder_name}" --driver docker-container --use
  else
    docker buildx use "${builder_name}"
  fi

  docker buildx inspect --bootstrap
}

prepare_elastic_agent_files() {
  echo "Preparing files for elastic-agent Docker build..."
  for var in ES_CA_CERT CERT_FILE_PATH; do
    : "${!var:?Need to set $var}"
  done

  if ! aws ssm get-parameter --name "${ES_CA_CERT}" --with-decryption --query 'Parameter.Value' --output text > "client-ca.crt"; then
    echo "Error: Failed to retrieve ES_CA_CERT from SSM."
    exit 1
  fi
  temp_files+=("client-ca.crt")

  cat <<EOF > "Dockerfile.elastic-agent"
ARG TAG=latest
FROM elastic/elastic-agent:\${TAG}
RUN mkdir -p $(dirname "${CERT_FILE_PATH}")
COPY client-ca.crt ${CERT_FILE_PATH}
EOF
  temp_files+=("Dockerfile.elastic-agent")
}

build_and_push_elastic_agent_image() {
  local tag="$1"
  echo "Building and pushing elastic-agent image with tag ${tag}"

  for platform in "${platforms[@]}"; do
    docker buildx build --platform "${platform}" \
      --build-arg TAG="${tag}" \
      --file "Dockerfile.elastic-agent" \
      --tag "${REGISTRY}/elastic/elastic-agent:${tag}-${platform##*/}" \
      --push \
      .
  done
}

build_and_push_image() {
  local image="$1"
  local tag="$2"
  echo "Retagging and pushing ${image}:${tag} for platforms: ${platforms[*]}"

  for platform in "${platforms[@]}"; do
    docker pull --platform "${platform}" "${image}:${tag}"
    docker tag "${image}:${tag}" "${REGISTRY}/${image}:${tag}-${platform##*/}"
    docker push "${REGISTRY}/${image}:${tag}-${platform##*/}"
  done
}

build_and_push_images() {
  IFS=' ' read -ra images_tags_array <<< "${UPSTREAM_IMAGES_TAGS}"

  for image_tags in "${images_tags_array[@]}"; do
    local image=$(cut -d'=' -f1<<<"${image_tags}")
    local tags=$(cut -d'=' -f2<<<"${image_tags}")

    [[ "${image}" == "elastic/elastic-agent" ]] && prepare_elastic_agent_files

    IFS=',' read -ra tags_array <<< "${tags}"
    for tag in "${tags_array[@]}"; do
      if [[ "${image}" == "elastic/elastic-agent" ]]; then
        build_and_push_elastic_agent_image "${tag}"
      else
        build_and_push_image "${image}" "${tag}"
      fi
    done
  done
}

push_manifests() {
  IFS=' ' read -ra images_tags_array <<< "${UPSTREAM_IMAGES_TAGS}"

  for image_tags in "${images_tags_array[@]}"; do
    local image=$(cut -d'=' -f1<<<"${image_tags}")
    local tags=$(cut -d'=' -f2<<<"${image_tags}")
    IFS=',' read -ra tags_array <<< "${tags}"

    for tag in "${tags_array[@]}"; do
      if [[ "${image}" == "elastic/elastic-agent" ]]; then
        docker manifest create --amend \
          "${REGISTRY}/${image}:${tag}-linux/amd64" \
          "${REGISTRY}/${image}:${tag}-linux/arm64"
      else
        docker manifest create --amend \
          "${REGISTRY}/${image}:${tag}" \
          "${REGISTRY}/${image}:${tag}-linux/amd64" \
          "${REGISTRY}/${image}:${tag}-linux/arm64"
      fi

      docker manifest push "${REGISTRY}/${image}:${tag}"
    done
  done
}

print_usage_error() {
  echo "Error: Invalid or missing argument. Please specify 'setup', 'build', or 'push'."
}

if [[ $# -eq 0 ]]; then
  print_usage_error
  exit 1
fi

case "$1" in
  setup)
    check_env_vars
    docker_login
    ;;
  build)
    initialize_docker_buildx
    build_and_push_images
    ;;
  push)
    push_manifests
    ;;
  *)
    print_usage_error
    exit 1
    ;;
esac
