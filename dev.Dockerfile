FROM python:3.8-bullseye

# Needed for string substitution
SHELL ["/bin/bash", "-c"]

# To remove debconf build warnings
ARG DEBIAN_FRONTEND=noninteractive

# Change locale to fix encoding error on mail-parser install
ARG LC=ko_KR.UTF-8
RUN apt-get update \
 && apt-get install --no-install-suggests -y \
    locales \
 && locale-gen en_US.UTF-8 \
 && locale-gen ${LC} \
    ;
# Set default locale for the environment
ENV LC_ALL=C \
    LANG=${LC}

# Change the timezone
ARG TZ=Asia/Seoul
RUN ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime \
    ;

# Install essential programs
RUN apt-get update \
 && apt-get install --no-install-suggests -y \
    openssh-server \
    unzip \
    curl \
    wget \
    ssh \
    git \
    vim \
    bc \
    jq \
    ;

# Add user with sudo permission if not exists
ARG USER=dev
ARG PUID=1000
ARG PGID=1000
ARG DOCKER_GID=999
RUN PREV_GROUP=$(getent group ${PGID} | cut -d: -f1) \
 && if [ "${PREV_GROUP}" ]; then \
      groupmod -n ${USER} ${PREV_GROUP};\
    else \
      groupadd -g ${PGID} ${USER}; \
    fi \
    ;
RUN DOCKER_GROUP=$(getent group ${DOCKER_GID} | cut -d: -f1) \
 && if [ ! "${DOCKER_GROUP}" ]; then \
      groupadd -g ${DOCKER_GID} docker; \
    fi \
    ;
RUN PREV_USER=$(getent passwd ${PUID} | cut -d: -f1) \
 && if [ "${PREV_USER}" ]; then \
      echo "USERMOD"; \
      usermod \
        -m -d /home/${USER} \
        -l ${USER} -p ${USER} \
        -g ${USER} -aG docker \
        ${PREV_USER}; \
      newgrp; \
    else \
      echo "USERADD"; \
      useradd \
        -m -p ${USER} \
        -g ${USER} -G docker \
        ${USER}; \
    fi \
 && echo -e "${USER}:${USER}" | chpasswd \
 && exit 0
RUN apt-get update \
 && apt-get install --no-install-suggests -y \
    sudo \
 && echo "${USER} ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER} \
 && chmod 0440 /etc/sudoers.d/${USER} \
    ;

# Add s6 overlay
ARG OVERLAY_VERSION=v3.1.2.1
RUN OVERLAY_ARCH=$(uname -m) \
 && wget -P /tmp https://github.com/just-containers/s6-overlay/releases/download/${OVERLAY_VERSION}/s6-overlay-noarch.tar.xz \
 && wget -P /tmp https://github.com/just-containers/s6-overlay/releases/download/${OVERLAY_VERSION}/s6-overlay-symlinks-noarch.tar.xz \
 && wget -P /tmp https://github.com/just-containers/s6-overlay/releases/download/${OVERLAY_VERSION}/s6-overlay-${OVERLAY_ARCH}.tar.xz \
 && tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz \
 && tar -C / -Jxpf /tmp/s6-overlay-symlinks-noarch.tar.xz \
 && tar -C / -Jxpf /tmp/s6-overlay-${OVERLAY_ARCH}.tar.xz \
 && rm /tmp/s6-overlay-noarch.tar.xz \
 && rm /tmp/s6-overlay-symlinks-noarch.tar.xz \
 && rm /tmp/s6-overlay-${OVERLAY_ARCH}.tar.xz \
    ;

# Add local files
COPY .devcontainer/rootfs/ /

# Install code-server (from linuxserver/docker-code-server)
ARG CODE_RELEASE=4.11.0
RUN echo "**** install runtime dependencies ****" \
 && apt-get update \
 && apt-get install --no-install-suggests -y \
    git \
    jq \
    libatomic1 \
    nano \
    net-tools \
    netcat \
    sudo \
 && echo "**** install code-server ****" \
 && if [ -z ${CODE_RELEASE+x} ]; then \
      CODE_RELEASE=$(curl -sX GET https://api.github.com/repos/coder/code-server/releases/latest \
      | awk '/tag_name/{print $4;exit}' FS='[""]' | sed 's|^v||'); \
    fi \
 && mkdir -p /app/code-server \
 && curl -o /tmp/code-server.tar.gz -L \
    "https://github.com/coder/code-server/releases/download/v${CODE_RELEASE}/code-server-${CODE_RELEASE}-linux-amd64.tar.gz" \
 && tar xf /tmp/code-server.tar.gz -C /app/code-server --strip-components=1 \
 && echo "**** clean up ****" \
 && apt-get clean \
 && rm -rf \
    /config/* \
    /tmp/* \
    /var/lib/apt/lists/* \
    /var/tmp/*

ARG COMPOSE_IMAGE_NAME=app
RUN mkdir -p /etc/services.d/code-server \
 && set -x \
 && { \
    echo '#!/usr/bin/with-contenv bash'; \
    echo ''; \
    echo "EXTENSION_DIR=/home/${USER}/code-server/extensions"; \
    echo 'mkdir -p ${EXTENSION_DIR}'; \
    echo "jq -rc '.recommendations[]' /app/${COMPOSE_IMAGE_NAME}/.vscode/extensions.json | while read i; do"; \
    echo '  /app/code-server/bin/code-server \'; \
    echo '    --extensions-dir ${EXTENSION_DIR} \'; \
    echo '    --install-extension ${i}'; \
    echo '  ls ${EXTENSION_DIR}/${i}* > /dev/null 2>&1'; \
    echo '  if [ $? -ne 0 ]; then'; \
    echo '    echo "Installing ${i} from GitHub";'; \
    echo '    IFS="." read -ra extname <<< "${i}"'; \
    echo '    curl -o ${EXTENSION_DIR}/${i}.vsix -L \';  \
    echo '      https://github.gallery.vsassets.io/_apis/public/gallery/publisher/${extname[0]}/extension/${extname[1]}/latest/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage'; \
    echo '    /app/code-server/bin/code-server \'; \
    echo '      --extensions-dir ${EXTENSION_DIR} \'; \
    echo '      --install-extension ${EXTENSION_DIR}/${i}.vsix'; \
    echo '  fi'; \
    echo 'done'; \
    echo ''; \
    echo ''; \
    echo '/app/code-server/bin/code-server \'; \
    echo '--bind-addr 0.0.0.0:8443 \'; \
    echo "--user-data-dir /home/${USER}/code-server/config \\"; \
    echo "--extensions-dir /home/${USER}/code-server/extensions \\"; \
    echo '--disable-telemetry \'; \
    echo '--auth "none" \'; \
    echo "/app/${COMPOSE_IMAGE_NAME}"; \
 } > /etc/services.d/code-server/run \
 && chmod +x /etc/services.d/code-server/run \
 && cat /etc/services.d/code-server/run

EXPOSE 8443
ENTRYPOINT [ "/init" ]

# Set working directory
WORKDIR /app/${COMPOSE_IMAGE_NAME}
ENV PATH /home/${USER}/.local/bin:$PATH
