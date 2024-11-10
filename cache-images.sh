#!/usr/bin/env bash

set -euo pipefail

temp_files=()
oses=("linux")
arches=("amd64" "arm64")
platforms=()
declare -A image_tags

cleanup() {
  echo "Cleaning up temporary files..."
  if [[ ${#temp_files[@]} -gt 0 ]]; then
    rm -f "${temp_files[@]}"
  fi
}
trap cleanup EXIT

check_env_vars() {
  echo "Checking environment variables..."
  for var in AWS_REGION REGISTRY UPSTREAM_IMAGES_TAGS; do
    : "${!var:?Need to set $var}"
  done
}

build_data_structures() {
  echo "Building data structures..."
  for os in "${oses[@]}"; do
    for arch in "${arches[@]}"; do
      platforms+=("${os}/${arch}")
    done
  done

  for entry in ${UPSTREAM_IMAGES_TAGS}; do
    IFS='=' read -r image tags <<< "${entry}"
    IFS=',' read -ra tags_array <<< "${tags}"
    image_tags["$image"]="${tags_array[@]}"
  done
}

docker_login() {
  echo "Logging into Docker registry..."
  if ! aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${REGISTRY}"  >/dev/null; then
    echo "Error: Docker login failed."
    exit 1
  fi
}

initialize_docker_buildx() {
  echo "Initializing Docker Buildx..."
  local builder_name="multiarch-builder"

  if ! docker buildx inspect "${builder_name}" >/dev/null 2>&1; then
    docker buildx create --name "${builder_name}" --driver docker-container --use >/dev/null
  else
    docker buildx use "${builder_name}" >/dev/null
  fi

  docker buildx inspect --bootstrap >/dev/null
}


prepare_elastic_agent_files() {
  echo "Preparing files for elastic-agent Docker build..."
  for var in ES_CA_CERT CERT_FILE_PATH; do
    : "${!var:?Need to set $var}"
  done

  if ! aws --profile=gm ssm get-parameter --name "${ES_CA_CERT}" --with-decryption --query 'Parameter.Value' --output text > "client-ca.crt"; then
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

build_elastic_agent_image() {
  local tag="$1"
  echo "Building and pushing elastic-agent image with tag ${tag}"

  for platform in "${platforms[@]}"; do
    docker buildx build --platform "${platform}" \
      --build-arg TAG="${tag}" \
      --file "Dockerfile.elastic-agent" \
      --output type=docker \
      --cache-to type=local,dest=/tmp \
      --cache-from type=local,src=/tmp \
      --tag "${REGISTRY}/elastic/elastic-agent:${tag}-${platform##*/}" \
      --load \
      .
  done
}

build_image() {
  local image="$1"
  local tag="$2"
  echo "Retagging and pushing ${image}:${tag} for platforms: ${platforms[*]}"

  for platform in "${platforms[@]}"; do
    docker pull --platform "${platform}" "${image}:${tag}"
    docker tag "${image}:${tag}" "${REGISTRY}/${image}:${tag}-${platform##*/}"
    # docker push "${REGISTRY}/${image}:${tag}-${platform##*/}"
  done
}

build_images() {
  IFS=' ' read -ra images_tags_array <<< "${UPSTREAM_IMAGES_TAGS}"

  for image_tags in "${images_tags_array[@]}"; do
    local image=$(cut -d'=' -f1<<<"${image_tags}")
    local tags=$(cut -d'=' -f2<<<"${image_tags}")

    [[ "${image}" == "elastic/elastic-agent" ]] && prepare_elastic_agent_files

    IFS=',' read -ra tags_array <<< "${tags}"
    for tag in "${tags_array[@]}"; do
      if [[ "${image}" == "elastic/elastic-agent" ]]; then
        build_elastic_agent_image "${tag}"
      else
        build_image "${image}" "${tag}"
      fi
    done
  done
}

push_images_manifests() {
  IFS=' ' read -ra images_tags_array <<< "${UPSTREAM_IMAGES_TAGS}"

  for image_tags in "${images_tags_array[@]}"; do
    local image=$(cut -d'=' -f1 <<< "${image_tags}")
    local tags=$(cut -d'=' -f2 <<< "${image_tags}")
    IFS=',' read -ra tags_array <<< "${tags}"

    for tag in "${tags_array[@]}"; do
      docker push "${REGISTRY}/${image}:${tag}-amd64"
      docker push "${REGISTRY}/${image}:${tag}-arm64"

      if [[ "${image}" == "elastic/elastic-agent" ]]; then
        docker manifest create --amend \
          "${REGISTRY}/${image}:${tag}-amd64" \
          "${REGISTRY}/${image}:${tag}-arm64"
      else
        docker manifest create --amend \
          "${REGISTRY}/${image}:${tag}" \
          "${REGISTRY}/${image}:${tag}-amd64" \
          "${REGISTRY}/${image}:${tag}-arm64"
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
    build_data_structures
    docker_login
    initialize_docker_buildx
    ;;
  build)
    # initialize_docker_buildx
    # build_images
    ;;
  push)
    push_images_manifests
    ;;
  *)
    print_usage_error
    exit 1
    ;;
esac
