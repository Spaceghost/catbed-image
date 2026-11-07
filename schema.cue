package catbed

import "strings"

// #Machine is everything the installer needs to lay down a bare system that
// `oldbook-rebuild` can then finish. It deliberately stops at the boundary
// RECOVERY.md draws: disk, boot, base user, base services. The desktop, the
// theme, the boot palette and every service whose init script ships from the
// ~/.files checkout are the rebuild's job, not this file's.
#Machine: {
	hostname: string & =~"^[a-z0-9-]+$"
	model:    string
	timezone: string

	disk: {
		// The installer never trusts this default; it asks for the device
		// and makes you type its name back before touching it.
		device: string & =~"^/dev/"
		efi: {
			sizeMiB: int & >=100
			mount:   "/boot"
		}
		luks: {
			type:      "luks2"
			cipher:    string
			keyBits:   256 | 512
			pbkdf:     "argon2id" | "argon2i" | "pbkdf2"
			timeCost:  int & >0
			memoryKiB: int & >0
			threads:   int & >0
			hash:      string
			mapper:    string & =~"^[a-z0-9_-]+$"
		}
		lvm: {
			vg:      string & =~"^[a-z0-9_]+$"
			swapGiB: int & >=0
			rootFs:  "ext4"
		}
	}

	boot: {
		loader: "grub-efi"
		kernel: "lts"
		// Tokens before the managed boot-console ones; install-boot-console
		// appends the VT palette and font later and must find these intact.
		cmdline: [...string]
		initfsFeatures: [...string]
		grubDefaults: [string]: string
	}

	user: {
		name:   string & =~"^[a-z_][a-z0-9_-]*$"
		uid:    int & >=1000
		groups: [...string]
		shell:  string
	}

	// Only the general rule. The narrow remote-access grants belong to the
	// rebuild, which installs the binary they name.
	doas: [...string]

	// Runlevels as observed on the machine. Services whose init script does
	// not exist after the package install come from ~/.files; the installer
	// reports them and leaves them to oldbook-rebuild.
	services: [Runlevel=("sysinit" | "boot" | "default" | "shutdown")]: [...string]

	packages: {
		lock:         string & =~"^alpine/packages/locks/.+\\.json$"
		fossilBranch: string
	}

	iso: {
		label: string & strings.MaxRunes(32)
		// Needed to build or boot the ISO but absent from the lock; fetched
		// from Alpine edge at build time and hash-recorded in the manifest.
		extras: [...string]
	}
}
