FROM mcr.microsoft.com/devcontainers/base:debian-13
# --- mise: tool manager (same as the main k3s workspace) ---------------------
RUN curl -sSLf https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh && \
    echo 'eval "$(mise activate bash)"' >> /home/vscode/.bashrc && \
    echo 'eval "$(mise activate zsh)"'  >> /home/vscode/.zshrc

# --- Nix: single-user, NO daemon (works without systemd in a container) ------
# Installed as the `vscode` user (uses passwordless sudo to create /nix, then
# chowns it to vscode) so the store is user-owned. Flakes enabled.
#
# ⚠️ Do NOT bind-mount a volume at /nix: an empty volume would SHADOW this baked
#    store and `nix` would vanish on first start. The store lives in the image;
#    it is rebuilt only when the image is rebuilt (infrequent). To trade image
#    size for rebuild-speed, move the Nix install into scripts/setup and mount a
#    /nix volume instead (advanced — see .devcontainer/devcontainer.json note).
USER vscode
RUN curl -L https://nixos.org/nix/install -o /tmp/nix-install.sh && \
    sh /tmp/nix-install.sh --no-daemon && \
    rm /tmp/nix-install.sh && \
    mkdir -p /home/vscode/.config/nix && \
    printf 'experimental-features = nix-command flakes\n' \
      >> /home/vscode/.config/nix/nix.conf && \
    echo '. /home/vscode/.nix-profile/etc/profile.d/nix.sh' >> /home/vscode/.bashrc && \
    echo '. /home/vscode/.nix-profile/etc/profile.d/nix.sh' >> /home/vscode/.zshrc
USER root
