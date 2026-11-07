package catbed

import "strings"

// catbed: MacBookPro11,5, Alpine edge. Values recorded from the running
// machine on 2026-11-06 (sfdisk, lvs, cryptsetup luksDump, rc-update show).
machine: #Machine & {
	hostname: "catbed"
	model:    "MacBookPro11,5"
	timezone: "America/Los_Angeles"

	disk: {
		device: "/dev/sda" // APPLE SSD SM0512, 465.9 GiB
		efi: sizeMiB: 300
		luks: {
			type:      "luks2"
			cipher:    "aes-xts-plain64"
			keyBits:   512
			pbkdf:     "argon2id"
			timeCost:  6
			memoryKiB: 1048576
			threads:   4
			hash:      "sha256"
			mapper:    "root"
		}
		lvm: {
			vg:      "vg0"
			swapGiB: 4
			rootFs:  "ext4"
		}
	}

	boot: {
		loader: "grub-efi"
		kernel: "lts"
		cmdline: [
			"modules=sd-mod,usb-storage,ext4",
			"cryptroot=UUID=@CRYPT_UUID@",
			"cryptdm=\(disk.luks.mapper)",
			"quiet",
			"rootfstype=ext4",
		]
		initfsFeatures: ["ata", "base", "ide", "scsi", "usb", "virtio", "ext4", "lvm", "cryptsetup", "keymap"]
		grubDefaults: {
			GRUB_TIMEOUT:            "3"
			GRUB_DISABLE_SUBMENU:    "y"
			GRUB_DISABLE_RECOVERY:   "true"
			GRUB_CMDLINE_LINUX_DEFAULT: strings.Join(cmdline, " ")
		}
	}

	user: {
		name:   "jack"
		uid:    1000
		groups: ["wheel", "audio", "input", "video", "netdev"]
		shell:  "/bin/zsh"
	}

	doas: ["permit nopass :wheel"]

	services: {
		sysinit: ["devfs", "dmesg", "udev", "udev-settle", "udev-trigger"]
		boot: [
			"bootmisc", "hostname", "hwclock", "lvm", "modules", "networking",
			"seedrng", "swap", "sysctl", "syslog", "wpa_supplicant",
			// From ~/.files; skipped by the installer, enabled by the rebuild.
			"oldbook-catmode", "oldbook-firewall", "opensnitchd",
		]
		default: [
			"cgroups", "chronyd", "crond", "dbus", "elogind", "udev", "udev-postmount",
			"guix-daemon", "tailscale",
			// greetd is enabled by oldbook-rebuild once autologin is configured.
			"oldbook-remote-access",
		]
		shutdown: ["killprocs", "mount-ro", "savecache"]
	}

	packages: {
		lock:         "alpine/packages/locks/a39763a9ea503b106be7.json"
		fossilBranch: "alpine-oldbook"
	}

	iso: {
		label:  "CATBED"
		extras: ["syslinux", "mtools", "xorriso"]
	}
}

// Services whose init scripts come from the ~/.files checkout. Enabling one of
// these before its daemon exists would, for oldbook-firewall, fail closed and
// take networking with it.
fromCheckout: ["oldbook-catmode", "oldbook-firewall", "opensnitchd", "oldbook-remote-access"]

_q: {
	#in: string
	out: "'" + strings.Replace(#in, "'", "'\\''", -1) + "'"
}

// machine.env: flat, shell-quoted, sourced by catbed-install under ash.
_env: {
	MACHINE_HOSTNAME: machine.hostname
	MODEL:          machine.model
	TIMEZONE:       machine.timezone
	DISK_DEFAULT:   machine.disk.device
	EFI_MIB:        "\(machine.disk.efi.sizeMiB)"
	LUKS_CIPHER:    machine.disk.luks.cipher
	LUKS_KEYBITS:   "\(machine.disk.luks.keyBits)"
	LUKS_PBKDF:     machine.disk.luks.pbkdf
	LUKS_TIME:      "\(machine.disk.luks.timeCost)"
	LUKS_MEMORY:    "\(machine.disk.luks.memoryKiB)"
	LUKS_THREADS:   "\(machine.disk.luks.threads)"
	LUKS_HASH:      machine.disk.luks.hash
	LUKS_MAPPER:    machine.disk.luks.mapper
	VG:             machine.disk.lvm.vg
	SWAP_GIB:       "\(machine.disk.lvm.swapGiB)"
	USER_NAME:      machine.user.name
	USER_UID:       "\(machine.user.uid)"
	USER_GROUPS:    strings.Join(machine.user.groups, " ")
	USER_SHELL:     machine.user.shell
	SVC_SYSINIT:    strings.Join(machine.services.sysinit, " ")
	SVC_BOOT:       strings.Join(machine.services.boot, " ")
	SVC_DEFAULT:    strings.Join(machine.services.default, " ")
	SVC_SHUTDOWN:   strings.Join(machine.services.shutdown, " ")
	FROM_CHECKOUT:  strings.Join(fromCheckout, " ")
	LOCK_PATH:      machine.packages.lock
	FOSSIL_BRANCH:  machine.packages.fossilBranch
}

render: {
	env: strings.Join([for k, v in _env {"\(k)=\((_q & {#in: v}).out)"}], "\n") + "\n"

	// Files copied onto the target before any package is installed, so the
	// kernel's first mkinitfs already carries cryptsetup and lvm. @...@ tokens
	// are filled in by the installer once the disk exists.
	files: {
		"etc/hostname": machine.hostname + "\n"
		"etc/hosts": """
			127.0.0.1	\(machine.hostname).my.domain \(machine.hostname) localhost.localdomain localhost
			::1		localhost localhost.localdomain

			"""
		"etc/fstab": """
			/dev/\(machine.disk.lvm.vg)/lv_root	/	ext4	rw,relatime	0 1
			UUID=@ESP_UUID@	/boot	vfat	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=utf8,shortname=mixed,errors=remount-ro	0 2
			/dev/\(machine.disk.lvm.vg)/lv_swap	none	swap	defaults	0 0
			tmpfs	/tmp	tmpfs	nosuid,nodev	0	0

			"""
		"etc/mkinitfs/mkinitfs.conf": "features=\"\(strings.Join(machine.boot.initfsFeatures, " "))\"\n"
		"etc/default/grub": strings.Join([for k, v in machine.boot.grubDefaults {"\(k)=\"\(v)\""}], "\n") + "\n"
		"etc/doas.d/catbed-base.conf": strings.Join(machine.doas, "\n") + "\n"
		"etc/network/interfaces": """
			auto lo
			iface lo inet loopback
			iface lo inet6 loopback

			auto wlan0
			iface wlan0 inet dhcp
			iface wlan0 inet6 dhcp

			"""
		"etc/conf.d/wpa_supplicant": "wpa_supplicant_args=\"-i wlan0\"\n"
		// No networks: saved Wi-Fi PSKs are machine identity, never in the
		// image. Join with `wpa_cli` on first boot or restore per RECOVERY.md.
		"etc/wpa_supplicant/wpa_supplicant.conf": """
			ctrl_interface=DIR=/run/wpa_supplicant
			update_config=1

			"""
	}

	isoExtras: machine.iso.extras
	isoLabel:  machine.iso.label
	lock:      machine.packages.lock
}
