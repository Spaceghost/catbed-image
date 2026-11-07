# catbed-common.sh: laying the catbed system into a root directory, shared by
# catbed-install (onto a real disk, from the ISO) and builder/build-rootfs.sh
# (into a directory, for the rootfs tarball and the qcow2). Sourced, not run.
#
# Callers set: CONF (dir holding machine.env, world, repositories, keys/,
# target*/, catbed-firstboot), TARGET (root being filled), REPO (apk repo the
# closure comes from) and PLAN (1 = print only). machine.env must be sourced.
# shellcheck shell=sh

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }
run() {
    if [ "${PLAN:-0}" = 1 ]; then say "  would run: $*"; return 0; fi
    "$@"
}
in_target() { run chroot "$TARGET" "$@"; }

# lay_config FILES_DIR ESP_UUID CRYPT_UUID ROOT_UUID
# Copy the rendered /etc files, filling the @...@ tokens; install apk keys,
# point every world tag at REPO for the duration of the install, set the zone.
# Pass the literal tokens to leave them unresolved (the rootfs tarball does).
lay_config() {
    files=$1 esp=$2 crypt=$3 rootuuid=$4
    if [ "${PLAN:-0}" = 1 ]; then
        (cd "$files" && find . -type f) | sed 's|^\.|  would write: '"$TARGET"'|'
        return 0
    fi
    (cd "$files" && find . -type f) | while read -r rel; do
        dest=$TARGET/${rel#./}
        mkdir -p "$(dirname "$dest")"
        sed -e "s|@ESP_UUID@|$esp|g" -e "s|@CRYPT_UUID@|$crypt|g" \
            -e "s|@ROOT_UUID@|$rootuuid|g" "$files/$rel" > "$dest"
    done
    chmod 600 "$TARGET/etc/wpa_supplicant/wpa_supplicant.conf"
    chmod 600 "$TARGET/etc/doas.d/catbed-base.conf"
    mkdir -p "$TARGET/etc/apk/keys"
    cp "$CONF/keys/"* "$TARGET/etc/apk/keys/"
    printf '%s\n@testing %s\n@1password %s\n@personal %s\n' \
        "$REPO" "$REPO" "$REPO" "$REPO" > "$TARGET/etc/apk/repositories"
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"
    printf '%s\n' "$TIMEZONE" > "$TARGET/etc/timezone"
}

# install_closure: the lock's world, offline from REPO, then hand the machine
# the lock's own repositories (REPO kept, commented, for offline repair).
install_closure() {
    # shellcheck disable=SC2046
    run apk add --root "$TARGET" --initdb --arch x86_64 --no-cache \
        --keys-dir "$TARGET/etc/apk/keys" \
        --repositories-file "$TARGET/etc/apk/repositories" \
        $(cat "$CONF/world")
    [ "${PLAN:-0}" = 1 ] && return 0
    cp "$CONF/world" "$TARGET/etc/apk/world"
    { printf '#%s\n' "$REPO"; grep -v '^#' "$CONF/repositories"; } > "$TARGET/etc/apk/repositories"
}

# create_user: account and groups only. Passwords are the caller's business:
# the installer asks at the console; images leave the account locked.
create_user() {
    in_target adduser -D -u "$USER_UID" -s "$USER_SHELL" "$USER_NAME"
    for group in $USER_GROUPS; do
        in_target addgroup "$USER_NAME" "$group"
    done
}

# enable_services: the observed runlevels, minus services ~/.files installs
# (enabling oldbook-firewall before OpenSnitch exists would cut networking).
enable_services() {
    for level in sysinit boot default shutdown; do
        case $level in
            sysinit) list=$SVC_SYSINIT ;; boot) list=$SVC_BOOT ;;
            default) list=$SVC_DEFAULT ;; shutdown) list=$SVC_SHUTDOWN ;;
        esac
        for svc in $list; do
            case " $FROM_CHECKOUT " in
                *" $svc "*) say "  left for oldbook-rebuild: $svc ($level)"; continue ;;
            esac
            if [ "${PLAN:-0}" = 1 ] || [ -e "$TARGET/etc/init.d/$svc" ]; then
                in_target rc-update add "$svc" "$level" >/dev/null
            else
                say "  no init script after install, skipped: $svc ($level)"
            fi
        done
    done
}

# build_initramfs: for the newest kernel present in the target.
build_initramfs() {
    if [ "${PLAN:-0}" = 1 ]; then in_target mkinitfs '<kernel-version>'; return 0; fi
    kver=
    for dir in "$TARGET"/lib/modules/*; do kver=${dir##*/}; done
    [ -n "$kver" ] || die 'no kernel modules in the target'
    in_target mkinitfs "$kver"
}

# place_checkout PAYLOAD_DIR: the Fossil database and an opened ~/.files.
place_checkout() {
    payload=$1 home=/home/$USER_NAME
    if [ -f "$payload/files.fossil" ]; then
        run install -d -m 700 -o "$USER_UID" -g "$USER_UID" \
            "$TARGET$home/.local" "$TARGET$home/.local/share" "$TARGET$home/.local/share/fossil"
        run install -m 600 -o "$USER_UID" -g "$USER_UID" \
            "$payload/files.fossil" "$TARGET$home/.local/share/fossil/files.fossil"
        in_target su -s /bin/sh "$USER_NAME" -c \
            "mkdir -p ~/.files && cd ~/.files && fossil open --quiet ~/.local/share/fossil/files.fossil $FOSSIL_BRANCH >/dev/null"
    else
        say '  no files.fossil available; follow RECOVERY.md steps 2-4 after first boot'
    fi
}

# stamp_handoff MANIFEST: catbed-firstboot, provenance and the login hint.
stamp_handoff() {
    run install -m 755 "$CONF/catbed-firstboot" "$TARGET/usr/local/bin/catbed-firstboot"
    [ "${PLAN:-0}" = 1 ] && return 0
    mkdir -p "$TARGET/var/lib/catbed"
    cp "$1" "$TARGET/var/lib/catbed/image-manifest.json" 2>/dev/null || true
    date -u +%Y-%m-%dT%H:%M:%SZ > "$TARGET/var/lib/catbed/installed-at"
    cat >> "$TARGET/etc/motd" <<EOF

  catbed base system installed. Log in as $USER_NAME and run:
      catbed-firstboot
  It hands over to ~/.files/alpine/bin/oldbook-rebuild.
EOF
}
