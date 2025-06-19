#!/usr/bin/env python3

import os
import subprocess
import urllib.request

MOUNT_DIR = "/mnt/boringos"

# --- Helpers ---
def run_command(cmd):
    print(f"🔧 Running: {cmd}")
    subprocess.run(cmd, shell=True, check=True)

def list_disks():
    print("📦 Detected Drives:")
    run_command("lsblk -dpno NAME,SIZE,MODEL,TYPE | grep -v 'loop\|sr\|zram'")

def select_disk():
    output = subprocess.check_output("lsblk -dpno NAME,TYPE | grep 'disk' | head -n 1", shell=True)
    return output.decode().split()[0]

def format_disk(disk):
    print(f"🧨 WARNING: All data on {disk} will be lost.")
    confirm = input("Are you REALLY sure you want to format this disk? Type 'yes': ")
    if confirm != "yes":
        print("❌ Cancelled.")
        exit(1)

    run_command(f"sudo umount {disk}* || true")
    run_command(f"sudo parted --script {disk} mklabel gpt \
                mkpart ESP fat32 1MiB 513MiB set 1 boot on \
                mkpart primary ext4 513MiB 100%")

    run_command(f"sudo mkfs.vfat -F32 {disk}1")
    run_command(f"sudo mkfs.ext4 -F {disk}2")

    os.makedirs(MOUNT_DIR, exist_ok=True)
    run_command(f"sudo mount {disk}2 {MOUNT_DIR}")
    os.makedirs(f"{MOUNT_DIR}/boot", exist_ok=True)
    run_command(f"sudo mount {disk}1 {MOUNT_DIR}/boot")

def create_swapfile(path, size_gb=2):
    swap_path = os.path.join(path, "swapfile")
    run_command(f"sudo fallocate -l {size_gb}G {swap_path}")
    run_command(f"sudo chmod 600 {swap_path}")
    run_command(f"sudo mkswap {swap_path}")
    run_command(f"sudo swapon {swap_path}")

def choose_stage3_variant():
    print("\n🧬 Choose your stage3 variant:")
    print("1) systemd (standard)")
    print("2) hardened + systemd (extra security)")
    choice = input("Enter choice [1/2]: ").strip()
    return "hardened+systemd" if choice == "2" else "systemd"

def get_latest_stage3_filename(variant):
    base_url = "https://distfiles.gentoo.org/releases/amd64/autobuilds"
    variant_path = f"current-stage3-amd64-{variant}"
    latest_txt_url = f"{base_url}/{variant_path}/latest-stage3-amd64-{variant}.txt"

    with urllib.request.urlopen(latest_txt_url) as response:
        latest_info = response.read().decode("utf-8").strip()

    latest_filename = latest_info.split()[0]
    return f"{base_url}/{variant_path}/{latest_filename}"

def download_stage3(variant):
    url = get_latest_stage3_filename(variant)
    filename = url.split("/")[-1]
    run_command(f"wget -c {url}")
    return filename

def extract_stage3(mount_dir, tarball):
    run_command(f"sudo tar xpf {tarball} -C {mount_dir} --xattrs-include='*.*' --numeric-owner")

def copy_portage_config(mount_dir):
    print("📁 Applying Git-based Portage configuration...")
    os.makedirs(f"{mount_dir}/etc/portage/repos.conf", exist_ok=True)
    run_command(f"sudo cp ./etc/portage/repos.conf/gentoo.conf {mount_dir}/etc/portage/repos.conf/")

def mount_special_fs(mount_dir):
    run_command(f"sudo mount --types proc /proc {mount_dir}/proc")
    run_command(f"sudo mount --rbind /sys {mount_dir}/sys")
    run_command(f"sudo mount --make-rslave {mount_dir}/sys")
    run_command(f"sudo mount --rbind /dev {mount_dir}/dev")
    run_command(f"sudo mount --make-rslave {mount_dir}/dev")

def enter_chroot(mount_dir):
    print("..hmm no package repository was added. This will take a bit.. Told you.. Boring.")
    print("🛠️  Time to chroot and compile. Boring is a feature, not a bug.")
    run_command(f"sudo chroot {mount_dir} /bin/bash")

# --- Main ---
print("🧽 Welcome to boringOS setup wizard")
list_disks()

DEFAULT_DRIVE = select_disk()
print(f"\n👉 Default drive candidate: {DEFAULT_DRIVE}")
confirm = input("Can I format this drive for boringOS? [y/N] ")

if confirm.lower() == 'y':
    format_disk(DEFAULT_DRIVE)
else:
    custom = input("Enter drive to partition manually (e.g. /dev/sda): ")
    run_command(f"sudo cfdisk {custom}")
    exit(0)

create_swapfile(MOUNT_DIR)
variant = choose_stage3_variant()
tarball = download_stage3(variant)
extract_stage3(MOUNT_DIR, tarball)
copy_portage_config(MOUNT_DIR)
mount_special_fs(MOUNT_DIR)
enter_chroot(MOUNT_DIR)
