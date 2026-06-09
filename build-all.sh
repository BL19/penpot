#!/usr/bin/env bash

# Penpot Complete Build Script - Builds everything using containers
# This script uses Docker to build all bundles and Docker images without requiring
# local dependencies (Node.js, Clojure, Rust, etc.)
#
# Usage:
#   ./build-all.sh [OPTIONS]
#
# Options:
#   --push              Push images to registry after build
#   --registry PREFIX   Registry prefix (default: cr.bl19.dev/penpot)
#   --version VERSION   Image version/tag (default: latest)
#   --devenv-image      Base devenv image (default: penpotapp/devenv:latest)
#   --help              Show this help message

set -e

# Default values
REGISTRY_PREFIX="${PENPOT_REGISTRY:-cr.bl19.dev/penpot}"
VERSION="${PENPOT_VERSION:-latest}"
PUSH_IMAGES=false
DEVENV_IMAGE="${PENPOT_DEVENV_IMAGE:-penpotapp/devenv:latest}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --push)
            PUSH_IMAGES=true
            shift
            ;;
        --registry)
            REGISTRY_PREFIX="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --devenv-image)
            DEVENV_IMAGE="$2"
            shift 2
            ;;
        --help)
            grep '^#' "$0" | tail -n +2
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_IMAGES_DIR="$SCRIPT_DIR/docker/images"
BUILD_DIR="$SCRIPT_DIR/.build-containers"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_section() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$*${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
}

# Verify Docker is available
if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    exit 1
fi

log_section "Penpot Complete Container Build"
log_info "Registry:    $REGISTRY_PREFIX"
log_info "Version:     $VERSION"
log_info "Push:        $PUSH_IMAGES"
log_info "Devenv:      $DEVENV_IMAGE"

# ============================================================================
# Build Frontend Bundle
# ============================================================================

log_section "Building Frontend Bundle"

FRONTEND_DOCKERFILE="$BUILD_DIR/Dockerfile.frontend-build"
mkdir -p "$BUILD_DIR"

cat > "$FRONTEND_DOCKERFILE" << 'EOF'
ARG DEVENV_IMAGE=penpotapp/devenv:latest
FROM ${DEVENV_IMAGE} AS builder

WORKDIR /workspace

# Copy frontend source
COPY frontend/ ./frontend/
COPY common/ ./common/

WORKDIR /workspace/frontend

# Build frontend
RUN npm install && npm run build:dist

# Output stage
FROM scratch
COPY --from=builder /workspace/frontend/dist /
EOF

log_info "Building frontend in container..."
if docker build \
    --build-arg DEVENV_IMAGE="$DEVENV_IMAGE" \
    -f "$FRONTEND_DOCKERFILE" \
    -t penpot-frontend-build:tmp \
    "$SCRIPT_DIR" > /tmp/frontend-build.log 2>&1; then
    log_success "Frontend built successfully"
    
    # Extract the bundle
    mkdir -p "$DOCKER_IMAGES_DIR/bundle-frontend"
    log_info "Extracting frontend bundle..."
    docker run --rm \
        -v "$DOCKER_IMAGES_DIR/bundle-frontend:/output" \
        --entrypoint sh \
        penpot-frontend-build:tmp \
        -c "cp -r / /output/" 2>/dev/null || true
    
    # Clean up and verify
    docker rmi penpot-frontend-build:tmp 2>/dev/null || true
    
    if [ -f "$DOCKER_IMAGES_DIR/bundle-frontend/index.html" ] || [ -f "$DOCKER_IMAGES_DIR/bundle-frontend/js/main.js" ]; then
        log_success "Frontend bundle extracted to docker/images/bundle-frontend/"
    else
        log_warning "Frontend bundle extracted but structure may differ from expected"
    fi
else
    log_error "Failed to build frontend"
    cat /tmp/frontend-build.log >&2
    exit 1
fi

# ============================================================================
# Build Backend Bundle
# ============================================================================

log_section "Building Backend Bundle"

BACKEND_DOCKERFILE="$BUILD_DIR/Dockerfile.backend-build"

cat > "$BACKEND_DOCKERFILE" << 'EOF'
ARG DEVENV_IMAGE=penpotapp/devenv:latest
FROM ${DEVENV_IMAGE} AS builder

WORKDIR /workspace

# Copy backend source
COPY backend/ ./backend/
COPY common/ ./common/

WORKDIR /workspace/backend

# Build backend
RUN clojure -T:build uber

# Output stage
FROM scratch
COPY --from=builder /workspace/backend/target/penpot-backend-*.jar /penpot-backend.jar
COPY --from=builder /workspace/backend/target/classes/run.sh /run.sh
EOF

log_info "Building backend in container..."
if docker build \
    --build-arg DEVENV_IMAGE="$DEVENV_IMAGE" \
    -f "$BACKEND_DOCKERFILE" \
    -t penpot-backend-build:tmp \
    "$SCRIPT_DIR" > /tmp/backend-build.log 2>&1; then
    log_success "Backend built successfully"
    
    # Extract the bundle
    mkdir -p "$DOCKER_IMAGES_DIR/bundle-backend"
    log_info "Extracting backend bundle..."
    docker run --rm \
        -v "$DOCKER_IMAGES_DIR/bundle-backend:/output" \
        --entrypoint sh \
        penpot-backend-build:tmp \
        -c "cp -r / /output/" 2>/dev/null || true
    
    # Clean up and verify
    docker rmi penpot-backend-build:tmp 2>/dev/null || true
    
    if [ -f "$DOCKER_IMAGES_DIR/bundle-backend/penpot-backend.jar" ]; then
        log_success "Backend bundle extracted to docker/images/bundle-backend/"
    else
        log_warning "Backend bundle extracted but JAR not found in expected location"
    fi
else
    log_error "Failed to build backend"
    cat /tmp/backend-build.log >&2
    exit 1
fi

# ============================================================================
# Build Exporter Bundle
# ============================================================================

log_section "Building Exporter Bundle"

EXPORTER_DOCKERFILE="$BUILD_DIR/Dockerfile.exporter-build"

cat > "$EXPORTER_DOCKERFILE" << 'EOF'
ARG DEVENV_IMAGE=penpotapp/devenv:latest
FROM ${DEVENV_IMAGE} AS builder

WORKDIR /workspace

# Copy exporter source
COPY exporter/ ./exporter/
COPY common/ ./common/

WORKDIR /workspace/exporter

# Build exporter
RUN npm install && npm run build

# Output stage
FROM scratch
COPY --from=builder /workspace/exporter/dist /
COPY --from=builder /workspace/exporter/package.json /
COPY --from=builder /workspace/exporter/package-lock.json /
EOF

log_info "Building exporter in container..."
if docker build \
    --build-arg DEVENV_IMAGE="$DEVENV_IMAGE" \
    -f "$EXPORTER_DOCKERFILE" \
    -t penpot-exporter-build:tmp \
    "$SCRIPT_DIR" > /tmp/exporter-build.log 2>&1; then
    log_success "Exporter built successfully"
    
    # Extract the bundle
    mkdir -p "$DOCKER_IMAGES_DIR/bundle-exporter"
    log_info "Extracting exporter bundle..."
    docker run --rm \
        -v "$DOCKER_IMAGES_DIR/bundle-exporter:/output" \
        --entrypoint sh \
        penpot-exporter-build:tmp \
        -c "cp -r / /output/" 2>/dev/null || true
    
    # Clean up and verify
    docker rmi penpot-exporter-build:tmp 2>/dev/null || true
    
    if [ -d "$DOCKER_IMAGES_DIR/bundle-exporter/dist" ]; then
        log_success "Exporter bundle extracted to docker/images/bundle-exporter/"
    else
        log_warning "Exporter bundle extracted but structure may differ from expected"
    fi
else
    log_error "Failed to build exporter"
    cat /tmp/exporter-build.log >&2
    exit 1
fi

# ============================================================================
# Build MCP Bundle
# ============================================================================

log_section "Building MCP Bundle"

MCP_DOCKERFILE="$BUILD_DIR/Dockerfile.mcp-build"

cat > "$MCP_DOCKERFILE" << 'EOF'
ARG DEVENV_IMAGE=penpotapp/devenv:latest
FROM ${DEVENV_IMAGE} AS builder

WORKDIR /workspace

# Copy MCP source
COPY mcp/ ./mcp/

WORKDIR /workspace/mcp

# Build MCP
RUN npm install && npm run build

# Output stage
FROM scratch
COPY --from=builder /workspace/mcp/dist /
COPY --from=builder /workspace/mcp/package.json /
COPY --from=builder /workspace/mcp/package-lock.json /
EOF

log_info "Building MCP in container..."
if docker build \
    --build-arg DEVENV_IMAGE="$DEVENV_IMAGE" \
    -f "$MCP_DOCKERFILE" \
    -t penpot-mcp-build:tmp \
    "$SCRIPT_DIR" > /tmp/mcp-build.log 2>&1; then
    log_success "MCP built successfully"
    
    # Extract the bundle
    mkdir -p "$DOCKER_IMAGES_DIR/bundle-mcp"
    log_info "Extracting MCP bundle..."
    docker run --rm \
        -v "$DOCKER_IMAGES_DIR/bundle-mcp:/output" \
        --entrypoint sh \
        penpot-mcp-build:tmp \
        -c "cp -r / /output/" 2>/dev/null || true
    
    # Clean up and verify
    docker rmi penpot-mcp-build:tmp 2>/dev/null || true
    
    if [ -d "$DOCKER_IMAGES_DIR/bundle-mcp/dist" ]; then
        log_success "MCP bundle extracted to docker/images/bundle-mcp/"
    else
        log_warning "MCP bundle extracted but structure may differ from expected"
    fi
else
    log_error "Failed to build MCP"
    cat /tmp/mcp-build.log >&2
    exit 1
fi

# ============================================================================
# Build Docker Images
# ============================================================================

log_section "Building Production Docker Images"

cd "$DOCKER_IMAGES_DIR"
log_info "Working directory: $(pwd)"

# Setup buildx
log_info "Setting up Docker Buildx..."

if ! docker run --privileged --rm tonistiigi/binfmt --install all > /dev/null 2>&1; then
    log_warning "Could not install binfmt for multi-platform builds"
fi

if ! docker buildx inspect penpot > /dev/null 2>&1; then
    log_info "Creating new buildx builder 'penpot'..."
    docker buildx create --name=penpot --use
else
    log_info "Using existing buildx builder 'penpot'..."
    docker buildx use penpot
fi

docker buildx inspect --bootstrap > /dev/null 2>&1
log_success "Buildx setup complete"

echo

declare -a IMAGES=("frontend" "backend" "exporter" "mcp")
declare -a BUILD_RESULTS

# Build each image
for IMAGE in "${IMAGES[@]}"; do
    log_info "Building Docker image for $IMAGE..."
    
    IMAGE_NAME="$REGISTRY_PREFIX/$IMAGE:$VERSION"
    
    OUTPUT="type=docker"
    if [ "$PUSH_IMAGES" = true ]; then
        OUTPUT="type=registry"
    fi
    
    if docker buildx build \
        --output "$OUTPUT" \
        --platform linux/amd64,linux/arm64 \
        -f "Dockerfile.$IMAGE" \
        -t "$IMAGE_NAME" \
        . > /tmp/penpot-docker-$IMAGE.log 2>&1; then
        log_success "$IMAGE Docker image built: $IMAGE_NAME"
        BUILD_RESULTS+=("✓ $IMAGE_NAME")
    else
        log_error "Failed to build Docker image for $IMAGE"
        BUILD_RESULTS+=("✗ $IMAGE_NAME (check /tmp/penpot-docker-$IMAGE.log)")
        cat /tmp/penpot-docker-$IMAGE.log >&2
    fi
    
    echo
done

# ============================================================================
# Summary
# ============================================================================

log_section "Build Complete Summary"
for result in "${BUILD_RESULTS[@]}"; do
    echo "  $result"
done
echo

log_info "Build logs:"
log_info "  Frontend build:  /tmp/frontend-build.log"
log_info "  Backend build:   /tmp/backend-build.log"
log_info "  Exporter build:  /tmp/exporter-build.log"
log_info "  MCP build:       /tmp/mcp-build.log"
log_info "  Docker builds:   /tmp/penpot-docker-*.log"
echo

# Cleanup
rm -rf "$BUILD_DIR"

if [ "$PUSH_IMAGES" = true ]; then
    log_success "All images built and pushed to $REGISTRY_PREFIX:$VERSION"
else
    log_success "All images built successfully!"
    log_info "To push to your registry:"
    for IMAGE in "${IMAGES[@]}"; do
        log_info "  docker push $REGISTRY_PREFIX/$IMAGE:$VERSION"
    done
fi

log_info "=========================================="
