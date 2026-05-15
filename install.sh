#!/bin/bash
# install.sh - install tailscale-watchdog and guide first-time setup.

set -e

usage() {
    cat <<EOF
Usage: $0

Installs tailscale-watchdog scripts, systemd units, and configuration.
When run from a terminal, it interactively offers to install Debian
dependencies, opens the config file in your editor, validates config, and
offers to enable the timer.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (try: sudo $0)" >&2
    exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR=/usr/local/bin
SYSTEMD_DIR=/etc/systemd/system
CONFIG_FILE=/etc/default/tailscale-watchdog
CONFIG_EXAMPLE="$REPO_DIR/etc/default/tailscale-watchdog.example"
WATCHDOG_BIN="$BIN_DIR/tailscale-watchdog.sh"

INTERACTIVE=0
[ -t 0 ] && INTERACTIVE=1

is_debian_like() {
    local os_id=""
    local os_id_like=""

    [ -r /etc/os-release ] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    os_id_like="${ID_LIKE:-}"

    case " $os_id $os_id_like " in
        *" debian "*|*" ubuntu "*) return 0 ;;
        *) return 1 ;;
    esac
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local suffix answer

    if [ "$INTERACTIVE" != "1" ]; then
        return 1
    fi

    if [ "$default" = "y" ]; then
        suffix="[Y/n]"
    else
        suffix="[y/N]"
    fi

    while true; do
        read -r -p "$prompt $suffix " answer
        answer="${answer:-$default}"
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
        esac
        echo "Please answer y or n."
    done
}

package_for_command() {
    case "$1" in
        curl) echo curl ;;
        dig) echo dnsutils ;;
        resolvectl) echo systemd-resolved ;;
        ip) echo iproute2 ;;
        ping) echo iputils-ping ;;
        *) return 1 ;;
    esac
}

add_package() {
    local pkg="$1"
    case " $APT_PACKAGES " in
        *" $pkg "*) ;;
        *) APT_PACKAGES="$APT_PACKAGES $pkg" ;;
    esac
}

install_debian_dependencies() {
    local cmd pkg
    APT_PACKAGES=""

    for cmd in curl dig resolvectl ip ping; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            pkg="$(package_for_command "$cmd")"
            add_package "$pkg"
        fi
    done

    if [ -z "$APT_PACKAGES" ]; then
        echo "Debian dependencies: OK"
        return
    fi

    echo "Missing Debian package dependencies:$APT_PACKAGES"
    if is_debian_like && command -v apt-get > /dev/null 2>&1; then
        if ask_yes_no "Install missing packages with apt-get?" "y"; then
            apt-get update
            # shellcheck disable=SC2086
            apt-get install -y $APT_PACKAGES
        else
            echo "Skipping dependency install."
        fi
    else
        echo "Install these packages manually for your distribution:$APT_PACKAGES"
    fi
}

install_tailscale_if_missing() {
    if command -v tailscale > /dev/null 2>&1; then
        echo "Tailscale CLI: OK"
        return
    fi

    echo "Tailscale CLI is missing."
    if command -v curl > /dev/null 2>&1; then
        if ask_yes_no "Install Tailscale using the official installer from tailscale.com?" "n"; then
            curl -fsSL https://tailscale.com/install.sh | sh
        else
            echo "Skipping Tailscale install. Install it later, then run: sudo tailscale up"
        fi
    else
        echo "Install curl first, then install Tailscale: https://tailscale.com/docs/install/linux"
    fi
}

install_files() {
    echo "Installing scripts to $BIN_DIR..."
    install -m 755 "$REPO_DIR/bin/tailscale-watchdog.sh" "$BIN_DIR/tailscale-watchdog.sh"
    install -m 755 "$REPO_DIR/bin/tailscale-recover.sh"  "$BIN_DIR/tailscale-recover.sh"
    install -m 755 "$REPO_DIR/bin/tailscale-diagnose.sh" "$BIN_DIR/tailscale-diagnose.sh"

    echo "Installing systemd units to $SYSTEMD_DIR..."
    install -m 644 "$REPO_DIR/systemd/tailscale-watchdog.service" "$SYSTEMD_DIR/tailscale-watchdog.service"
    install -m 644 "$REPO_DIR/systemd/tailscale-watchdog.timer"   "$SYSTEMD_DIR/tailscale-watchdog.timer"

    if [ ! -e "$CONFIG_FILE" ]; then
        echo "Installing example config to $CONFIG_FILE..."
        install -m 644 "$CONFIG_EXAMPLE" "$CONFIG_FILE"
    else
        echo "$CONFIG_FILE already exists, leaving it alone."
        echo "Compare against $CONFIG_EXAMPLE to see any new options."
    fi
}

detect_editor() {
    if [ -n "${SUDO_EDITOR:-}" ]; then
        echo "$SUDO_EDITOR"
        return 0
    fi
    if [ -n "${VISUAL:-}" ]; then
        echo "$VISUAL"
        return 0
    fi
    if [ -n "${EDITOR:-}" ]; then
        echo "$EDITOR"
        return 0
    fi

    for editor in sensible-editor editor nano vi; do
        if command -v "$editor" > /dev/null 2>&1; then
            echo "$editor"
            return 0
        fi
    done

    return 1
}

open_config_editor() {
    local editor_cmd

    if [ "$INTERACTIVE" != "1" ]; then
        echo "Edit $CONFIG_FILE before enabling the timer."
        return 1
    fi

    if ! editor_cmd="$(detect_editor)"; then
        echo "No editor found. Edit $CONFIG_FILE manually before enabling the timer."
        return 1
    fi

    echo ""
    echo "Opening $CONFIG_FILE with: $editor_cmd"
    echo "In the editor:"
    echo "  1. Set TAILSCALE_PROBE_URLS to one or more tailnet-only health URLs."
    echo "     Example:"
    echo "       TAILSCALE_PROBE_URLS=\"http://100.64.0.10/health http://nas.tailnet.local/health\""
    echo "  2. If you use headscale, set TAILSCALE_LOGIN_SERVER."
    echo "  3. Optionally set TAILNET_RESOLVERS for richer DNS/tunnel diagnostics."
    echo "Save and exit the editor; the installer will run a config check next."
    echo ""
    # Deliberately unquoted so EDITOR/VISUAL values with arguments work.
    # shellcheck disable=SC2086
    $editor_cmd "$CONFIG_FILE"
}

run_config_check() {
    if [ ! -x "$WATCHDOG_BIN" ]; then
        echo "Config check skipped: $WATCHDOG_BIN not installed."
        return 1
    fi

    if ask_yes_no "Run watchdog config check now?" "y"; then
        "$WATCHDOG_BIN" --check-config
        return $?
    fi

    return 1
}

maybe_enable_timer() {
    if ask_yes_no "Enable and start tailscale-watchdog.timer now?" "y"; then
        systemctl enable --now tailscale-watchdog.timer
        echo "Timer enabled."
    else
        echo "Timer not enabled. Enable later with:"
        echo "  sudo systemctl enable --now tailscale-watchdog.timer"
    fi
}

install_debian_dependencies
install_tailscale_if_missing
install_files
systemctl daemon-reload

echo ""
echo "Install complete."
open_config_editor || true

if run_config_check; then
    maybe_enable_timer
else
    echo ""
    echo "Config check did not pass or was skipped. After fixing config, run:"
    echo "  sudo tailscale-watchdog.sh --check-config"
    echo "  sudo systemctl enable --now tailscale-watchdog.timer"
fi

echo ""
echo "Useful commands:"
echo "  sudo tailscale-diagnose.sh"
echo "  sudo journalctl -u tailscale-watchdog.service -f"
