FROM fedora:44

# Install build dependencies
RUN dnf update -y && \
  dnf install -y --setopt=install_weak_deps=False \
  git \
  gcc \
  gcc-c++ \
  clang \
  cmake \
  make \
  pkgconfig \
  rpm-build \
  rust \
  cargo \
  cairo-devel \
  cairo-gobject-devel \
  glib2-devel \
  libdisplay-info-devel \
  libinput-devel \
  pipewire-devel \
  libxkbcommon-devel \
  mesa-libgbm-devel \
  pango-devel \
  pixman-devel \
  libseat-devel \
  libshaderc-devel \
  libxcb-devel \
  xcb-util-cursor-devel && \
  dnf clean all

# Install RPM helper binary globally so it is accessible to all container users
ENV CARGO_HOME=/usr/local/cargo
RUN cargo install cargo-generate-rpm --root /usr/local

# Set default workdir for mounts
WORKDIR /workspace

# Copy and set the builder entrypoints
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY entrypoint-satellite.sh /usr/local/bin/entrypoint-satellite.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/entrypoint-satellite.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
