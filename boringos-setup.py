#!/usr/bin/env python3

import os
import subprocess

print("""
🧽 Welcome to boringOS Ubuntu Setup Wizard

This will:
- Format a drive
- Bootstrap Ubuntu using debootstrap
- Set up chroot environment

Only proceed if you know what you’re doing.
""")

MOUNT_DIR = "/mnt/boringos"
UBUNTU_RELEASE = "noble"  # You can change this to focal, jammy, etc.
ARCH = "amd64"
MIRROR = "http://archive.ubuntu.com/ubuntu"

# --- Helpers ---
def run(cmd):
    print(f"🔧 {cmd}")
    subprocess.run(cmd, shell=True, check=True)

def list_disks():
    print("📦 Detected Drives:")
    run("lsblk -dpno NAME,SIZE,MODEL,TYPE | grep -v 'loop\|sr\|zram'")

def select_disk():
    output = subprocess.check_output("lsblk -dpno NAME,TYPE | grep 'disk' | head -n 1", shell=True)
    return output.decode().split()[0]

def format_disk(disk):
    print(f"🧨 WARNING: Formatting {disk}. This erases all data.")
    confirm = input("Type 'yes' to continue: ")
    if confirm != "yes":
        print("❌ Cancelled.")
        exit(1)

    run(f"sudo umount {disk}* || true")
    run(f"sudo parted --script {disk} mklabel gpt "
        "mkpart ESP fat32 1MiB 513MiB set 1 boot on "
        "mkpart primary ext4 513MiB 100%")
    run(f"sudo mkfs.vfat -F32 {disk}1")
    run(f"sudo mkfs.ext4 -F {disk}2")

    os.makedirs(MOUNT_DIR, exist_ok=True)
    run(f"sudo mount {disk}2 {MOUNT_DIR}")
    os.makedirs(f"{MOUNT_DIR}/boot", exist_ok=True)
    run(f"sudo mount {disk}1 {MOUNT_DIR}/boot")

def create_swapfile(path, size_gb=2):
    swap_path = os.path.join(path, "swapfile")
    run(f"sudo fallocate -l {size_gb}G {swap_path}")
    run(f"sudo chmod 600 {swap_path}")
    run(f"sudo mkswap {swap_path}")
    run(f"sudo swapon {swap_path}")

def debootstrap_ubuntu():
    print("📥 Bootstrapping Ubuntu...")
    run(f"sudo debootstrap --arch={ARCH} {UBUNTU_RELEASE} {MOUNT_DIR} {MIRROR}")

def mount_special_fs():
    run(f"sudo mount --types proc /proc {MOUNT_DIR}/proc")
    run(f"sudo mount --rbind /sys {MOUNT_DIR}/sys")
    run(f"sudo mount --make-rslave {MOUNT_DIR}/sys")
    run(f"sudo mount --rbind /dev {MOUNT_DIR}/dev")
    run(f"sudo mount --make-rslave {MOUNT_DIR}/dev")

def chroot_into_system():
    print("🛠️  Chrooting into new system...")
    run(f"sudo chroot {MOUNT_DIR} /bin/bash")

# --- Main ---
list_disks()
DEFAULT_DRIVE = select_disk()
print(f"👉 Default drive candidate: {DEFAULT_DRIVE}")
confirm = input("Use this drive for boringOS install? [y/N]: ")

if confirm.lower() == 'y':
    format_disk(DEFAULT_DRIVE)
else:
    custom = input("Enter disk manually (e.g. /dev/sdX): ")
    run(f"sudo cfdisk {custom}")
    exit(0)

create_swapfile(MOUNT_DIR)
debootstrap_ubuntu()
mount_special_fs()
chroot_into_system()
