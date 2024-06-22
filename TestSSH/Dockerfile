FROM quay.io/centos/centos:stream9

ARG BUILDARCH
ENV POWERSHELL_VERSION 7.4.2
EXPOSE 22

# Install packages.
RUN dnf install -y krb5-libs libicu openssh-server openssl-libs passwd sudo wget zlib && \
    rm -rf /var/cache/yum/*

# Install PowerShell
RUN case "$BUILDARCH" in \
    "amd64") ARCH="x64" ;; \
    "arm64") ARCH="arm64" ;; \
    *) echo "unsupported architecture"; exit 1 ;; \
    esac && \
    mkdir -p /opt/microsoft/powershell/7 && \
    wget -qO- https://github.com/PowerShell/PowerShell/releases/download/v${POWERSHELL_VERSION}/powershell-${POWERSHELL_VERSION}-linux-${ARCH}.tar.gz | \
    tar -xz -C /opt/microsoft/powershell/7
RUN chmod +x /opt/microsoft/powershell/7
RUN ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh

# Add a user.
RUN useradd -g wheel -ms /bin/bash testuser
RUN echo 'secret' | passwd --stdin testuser

# Configure SSH
RUN ssh-keygen -A
RUN sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
RUN echo 'Subsystem powershell /usr/bin/pwsh -sshs -NoLogo' >> /etc/ssh/sshd_config

# Run sshd.
CMD /usr/sbin/sshd -o LogLevel=DEBUG2 -De
