#!/usr/bin/env python3

import os
import subprocess

MOUNT_DIR = "/mnt/boringos"

print("👋 Welcome to the boringOS setup environment")
print("This script installs base components and offers optional feature sets.\n")

# Ensure necessary directories are mounted
def mount_system_dirs():
    print("🔧 Mounting proc, sys, and dev if not already mounted...")
    mounts = {
        "proc": ["--types", "proc", "/proc"],
        "sys": ["--rbind", "/sys"],
        "dev": ["--rbind", "/dev"]
    }
    for key, args in mounts.items():
        target = os.path.join(MOUNT_DIR, key)
        if not os.path.ismount(target):
            subprocess.run(["sudo", "mount"] + args + [target], check=True)
            subprocess.run(["sudo", "mount", "--make-rslave", target], check=True)

# Run a command inside the chroot
def chroot_run(command):
    subprocess.run(["sudo", "chroot", MOUNT_DIR, "/bin/bash", "-c", f"source /etc/profile && {command}"], check=True)

# Install gentoo-kernel
def install_kernel():
    print("🧬 Installing gentoo-kernel...")
    chroot_run("emerge --sync && emerge --ask gentoo-kernel")

# Install systemd-boot
def install_bootloader():
    print("🧢 Installing systemd-boot to EFI partition...")
    chroot_run("bootctl install")

# Interactive selection of optional sets
def select_feature_sets():
    sets = {
        "1": ("media-server", "📦 Installing media-server set"),
        "2": ("desktop-base", "🖥️  Installing desktop-base set"),
        "3": ("steam-frontend", "🎮 Installing steam-frontend set"),
        "4": ("gnome-desktop", "🧬 Installing gnome-desktop set"),
        "5": ("kde-desktop", "🎨 Installing kde-desktop set"),
        "6": ("raid-tools", "🧰 Installing raid-tools set"),
        "7": ("boringos-tools", "🔧 Installing boringOS core tools")
    }

    print("🎛️  Optional Setup Modules")
    for key, (name, _) in sets.items():
        print(f" {key}) {name}")
    print(" 0) Done\n")

    selected = input("Enter your choices (e.g. 1 3 7): ").split()

    for choice in selected:
        if choice == "0":
            break
        elif choice in sets:
            name, msg = sets[choice]
            print(msg)
            chroot_run(f"emerge --ask @{name}")
        else:
            print(f"⚠️  Unknown option: {choice}")

if __name__ == "__main__":
    mount_system_dirs()
    install_kernel()
    install_bootloader()
    select_feature_sets()

    print("✅ Feature set installation complete. You may now continue configuring your system.")
    print("Tip: Run additional inside-chroot setup scripts or emerge packages as needed.")
