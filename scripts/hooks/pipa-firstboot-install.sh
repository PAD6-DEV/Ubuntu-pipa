#!/bin/bash
set -eux

if [ -n "${PIPA_FIRSTBOOT_DM:-}" ]; then
    FIRSTBOOT_DM="$PIPA_FIRSTBOOT_DM"
elif dpkg -l sddm 2>/dev/null | grep -q '^ii'; then
    FIRSTBOOT_DM=sddm
elif dpkg -l gdm3 2>/dev/null | grep -q '^ii'; then
    FIRSTBOOT_DM=gdm
else
    FIRSTBOOT_DM=gdm
fi

first_existing_file() {
    local candidate
    for candidate in "$@"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

install -Dm755 /dev/stdin /usr/local/bin/pipa-firstboot-setup <<'SETUP_EOF'
#!/bin/sh
set -eu

TITLE="Ubuntu Pipa Setup"
STATE_DIR=/var/lib/pipa-firstboot
SENTINEL="$STATE_DIR/needs-setup"
LOCK_FILE="$STATE_DIR/lock"
AUTOSTART_FILE=/root/.config/autostart/pipa-firstboot-setup.desktop
DEFAULT_HOSTNAME="pipa"
DEFAULT_SHELL="/bin/bash"
PIPA_FIRSTBOOT_DM="$(cat /etc/pipa-firstboot-dm 2>/dev/null || printf '%s' gdm)"

[ -f "$SENTINEL" ] || exit 0

mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

dialog_backend() {
    if command -v zenity >/dev/null 2>&1; then
        printf '%s\n' zenity
        return 0
    fi
    if command -v kdialog >/dev/null 2>&1; then
        printf '%s\n' kdialog
        return 0
    fi
    return 1
}

prompt_info() {
    message="$1"
    case "$(dialog_backend)" in
        zenity) zenity --info --title "$TITLE" --text "$message" >/dev/null 2>&1 || return 1 ;;
        kdialog) kdialog --title "$TITLE" --msgbox "$message" >/dev/null 2>&1 || return 1 ;;
    esac
}

prompt_error() {
    message="$1"
    case "$(dialog_backend)" in
        zenity) zenity --error --title "$TITLE" --text "$message" >/dev/null 2>&1 || true ;;
        kdialog) kdialog --title "$TITLE" --error "$message" >/dev/null 2>&1 || true ;;
    esac
}

trim_whitespace() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

prompt_required_text() {
    prompt="$1"
    default_value="${2:-}"
    while :; do
        case "$(dialog_backend)" in
            zenity) answer="$(zenity --entry --title "$TITLE" --text "$prompt" --entry-text "$default_value" 2>/dev/null)" || return 1 ;;
            kdialog) answer="$(kdialog --title "$TITLE" --inputbox "$prompt" "$default_value" 2>/dev/null)" || return 1 ;;
        esac
        answer="$(trim_whitespace "$answer")"
        if [ -n "$answer" ]; then printf '%s\n' "$answer"; return 0; fi
        prompt_error "This field cannot be empty."
    done
}

prompt_optional_text() {
    prompt="$1"
    default_value="${2:-}"
    case "$(dialog_backend)" in
        zenity) answer="$(zenity --entry --title "$TITLE" --text "$prompt" --entry-text "$default_value" 2>/dev/null)" || return 1 ;;
        kdialog) answer="$(kdialog --title "$TITLE" --inputbox "$prompt" "$default_value" 2>/dev/null)" || return 1 ;;
    esac
    trim_whitespace "$answer"
}

prompt_password() {
    prompt="$1"
    while :; do
        case "$(dialog_backend)" in
            zenity) password="$(zenity --entry --title "$TITLE" --text "$prompt" --hide-text 2>/dev/null)" || return 1 ;;
            kdialog) password="$(kdialog --title "$TITLE" --password "$prompt" 2>/dev/null)" || return 1 ;;
        esac
        [ -n "$password" ] || { prompt_error "Password cannot be empty."; continue; }
        case "$(dialog_backend)" in
            zenity) confirmation="$(zenity --entry --title "$TITLE" --text "Confirm the password." --hide-text 2>/dev/null)" || return 1 ;;
            kdialog) confirmation="$(kdialog --title "$TITLE" --password "Confirm the password." 2>/dev/null)" || return 1 ;;
        esac
        [ "$password" = "$confirmation" ] || { prompt_error "Passwords do not match. Please try again."; continue; }
        printf '%s\n' "$password"
        return 0
    done
}

valid_username() { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]*[$]?$'; }
valid_hostname() { printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'; }

dialog_backend >/dev/null || { echo "pipa-firstboot-setup: zenity or kdialog is required." >&2; exit 1; }

prompt_info "Welcome to Ubuntu for Xiaomi Pad 6.\n\nThis first-boot setup will create your user account, set the hostname, and then reboot into the normal login screen." || exit 0

while :; do
    fullname="$(prompt_optional_text 'Full name (optional):' '')" || exit 0
    username="$(prompt_required_text 'Username:' '')" || exit 0
    username="$(printf '%s' "$username" | tr '[:upper:]' '[:lower:]')"
    valid_username "$username" || { prompt_error "Invalid username."; continue; }
    id "$username" >/dev/null 2>&1 && { prompt_error "User '$username' already exists."; continue; }
    hostname="$(prompt_required_text 'Hostname:' "$DEFAULT_HOSTNAME")" || exit 0
    hostname="$(printf '%s' "$hostname" | tr '[:upper:]' '[:lower:]')"
    valid_hostname "$hostname" || { prompt_error "Invalid hostname."; continue; }
    password="$(prompt_password "Password for $username:")" || exit 0
    break
done

if [ -n "$fullname" ]; then
    useradd -m -G sudo -s "$DEFAULT_SHELL" -c "$fullname" "$username"
else
    useradd -m -G sudo -s "$DEFAULT_SHELL" "$username"
fi

printf 'root:%s\n%s:%s\n' "$password" "$username" "$password" | chpasswd
printf '%s\n' "$hostname" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 $hostname.localdomain $hostname
HOSTS

case "$PIPA_FIRSTBOOT_DM" in
    sddm) rm -f /etc/sddm.conf.d/10-firstboot-autologin.conf ;;
    gdm) rm -f /etc/gdm3/custom.conf /etc/gdm/custom.conf.d/10-firstboot-autologin.conf ;;
esac
rm -f "$AUTOSTART_FILE" "$SENTINEL"

prompt_info "Setup complete.\n\nUser '$username' was created, the hostname was set to '$hostname', and the system will now reboot." || true
systemctl reboot
SETUP_EOF

case "$FIRSTBOOT_DM" in
    sddm)
        SESSION_FILE="$(first_existing_file \
            /usr/share/wayland-sessions/plasmawayland.desktop \
            /usr/share/wayland-sessions/plasma.desktop \
            /usr/share/xsessions/plasma.desktop \
        )" || SESSION_FILE="/usr/share/wayland-sessions/plasma.desktop"
        SESSION_NAME="$(basename "${SESSION_FILE:-plasma}" .desktop)"

        install -d /etc/sddm.conf.d
        cat > /etc/sddm.conf.d/10-firstboot-autologin.conf <<EOF
[Autologin]
User=root
Session=$SESSION_NAME
Relogin=false
EOF
        ;;
    gdm)
        SESSION_FILE="$(first_existing_file \
            /usr/share/wayland-sessions/ubuntu.desktop \
            /usr/share/wayland-sessions/gnome.desktop \
            /usr/share/xsessions/ubuntu.desktop \
            /usr/share/xsessions/gnome.desktop \
        )" || true
        SESSION_NAME="$(basename "${SESSION_FILE:-ubuntu}" .desktop)"

        install -d /etc/gdm3
        cat > /etc/gdm3/custom.conf <<EOF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=root
WaylandEnable=true
DefaultSession=$SESSION_NAME.desktop
EOF
        # Ubuntu gdm PAM blocks root; firstboot needs root autologin.
        for pam in /etc/pam.d/gdm-autologin /etc/pam.d/gdm-password; do
            if [ -f "$pam" ]; then
                sed -i '/pam_succeed_if.so user != root/d' "$pam"
            fi
        done
        ;;
    *)
        echo "Unknown display manager: $FIRSTBOOT_DM" >&2
        exit 1
        ;;
esac

printf '%s\n' "$FIRSTBOOT_DM" > /etc/pipa-firstboot-dm

install -Dm644 /dev/stdin /root/.config/autostart/pipa-firstboot-setup.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Ubuntu Pipa First Boot Setup
Exec=sh -lc 'sleep 3; exec /usr/local/bin/pipa-firstboot-setup'
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

install -d /var/lib/pipa-firstboot
: > /var/lib/pipa-firstboot/needs-setup

echo 'root:root' | chpasswd

# Ensure sudo group has privileges (default on Ubuntu)
install -d /etc/sudoers.d
cat > /etc/sudoers.d/pipa-sudo <<'EOF'
%sudo ALL=(ALL:ALL) ALL
EOF
chmod 440 /etc/sudoers.d/pipa-sudo
