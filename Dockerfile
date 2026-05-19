FROM registry.redhat.io/ubi9/ubi:9.6-1760340943 as base

# Install core utilities
RUN dnf install coreutils --allowerasing -y && \
    dnf clean all

# Install base utilities and clean up
RUN dnf update -y --allowerasing && \
    dnf install -y --allowerasing make curl wget zip jq tar unzip git gnupg findutils diffutils && \
    dnf install -y --allowerasing python3 python3-setuptools python3-pip && \
    python3 --version && \
    dnf clean all && rm -rf /var/cache/yum

# Add Microsoft package signing key and repository for .NET SDK
RUN rpm --import https://packages.microsoft.com/keys/microsoft.asc && \
    echo -e "[dotnet]\nname=Microsoft .NET\nbaseurl=https://packages.microsoft.com/yumrepos/microsoft-rhel7.9-prod\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" \
    > /etc/yum.repos.d/microsoft-dotnet.repo

# Install .NET SDK 6.0
RUN dnf install -y --allowerasing dotnet-sdk-6.0 aspnetcore-runtime-6.0 && \
    dnf clean all && rm -rf /var/cache/yum

# Install Git LFS and cleanup
RUN curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.rpm.sh | bash && \
    dnf install -y --allowerasing git-lfs && \
    dnf clean all && rm -rf /var/cache/yum

# #Install Azure CLI
RUN rpm --import https://packages.microsoft.com/keys/microsoft.asc && \
    dnf install -y https://packages.microsoft.com/config/rhel/9.0/packages-microsoft-prod.rpm && \
    dnf install -y azure-cli-2.68.0-1.el9 && \
    az version && \
    dnf clean all

# Install PowerShell and cleanup
RUN curl -s https://packages.microsoft.com/config/rhel/8/prod.repo > /etc/yum.repos.d/microsoft.repo && \
    dnf install -y --allowerasing powershell && \
    dnf clean all && rm -rf /var/cache/yum

# Download Terraform 1.12.2 and unzip
RUN wget https://releases.hashicorp.com/terraform/1.12.2/terraform_1.12.2_linux_amd64.zip \
    && unzip terraform_1.12.2_linux_amd64.zip \
    && mv terraform /usr/local/bin/terraform \
    && chmod +x /usr/local/bin/terraform \
    && rm -rf terraform_1.12.2_linux_amd64.zip

# Install tflint
ARG TFLINT_VERSION=0.58.1
RUN curl -L -o /tmp/tflint.zip https://github.com/terraform-linters/tflint/releases/download/v${TFLINT_VERSION}/tflint_linux_amd64.zip \
    && unzip /tmp/tflint.zip -d /tmp \
    && mv /tmp/tflint /usr/local/bin/tflint \
    && chmod +x /usr/local/bin/tflint \
    && rm -rf /tmp/*

# Install Podman and docker-compatible wrapper
RUN dnf install -y podman podman-docker && \
    dnf clean all && rm -rf /var/cache/dnf

# Create non-root user for Azure DevOps agent and give Docker group access
RUN adduser azdo_agent -u 1001 -d /azdo_agent -s /bin/bash && \
    groupadd -f docker && \
    usermod -aG docker azdo_agent && \
    chmod 755 /azdo_agent && \
    chown azdo_agent:azdo_agent /azdo_agent

# Switch to non-root user
USER azdo_agent

# Set the working directory
WORKDIR /azdo_agent

# Copy start script
COPY --chown=azdo_agent:azdo_agent start.sh /start.sh
RUN chmod +x /start.sh

# Set entrypoint
ENTRYPOINT ["/bin/bash", "/start.sh"]