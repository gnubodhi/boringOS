#!/usr/bin/env python3

import subprocess
import os

def run(cmd, chroot=False, chroot_path="/mnt/gentoo"):
    if chroot:
        cmd = f'chroot {chroot_path} /bin/bash -c "source /etc/profile && {cmd}"'
    print(f"📦 Running: {cmd}")
    subprocess.run(cmd, shell=True, check=True)

def mount_chroot_env(mount_path="/mnt/gentoo"):
    subprocess.run(["mount", "--types", "proc", "/proc", f"{mount_path}/proc"], check=True)
    subprocess.run(["mount", "--rbind", "/sys", f"{mount_path}/sys"], check=True)
    subprocess.run(["mount", "--make-rslave", f"{mount_path}/sys"], check=True)
    subprocess.run(["mount", "--rbind", "/dev", f"{mount_path}/dev"], check=True)
    subprocess.run(["mount", "--make-rslave", f"{mount_path}/dev"], check=True)

def install_kernel_and_bootloader():
    run("emerge --quiet gentoo-kernel", chroot=True)
    run("bootctl install", chroot=True)

def select_and_install_sets():
    available_sets = [
        "media-server",
        "desktop",
        "steam",
        "kodi",
        "gnome",
        "kde",
        "nvidia-drivers",
        "raid",
    ]
    print("\n📦 Available package sets:")
    for i, s in enumerate(available_sets):
        print(f"  {i+1}. {s}")
    selected = input("\nEnter the numbers of the sets to install (comma-separated): ")
    indices = [int(x.strip()) - 1 for x in selected.split(",") if x.strip().isdigit()]
    selected_sets = [available_sets[i] for i in indices if 0 <= i < len(available_sets)]
    for s in selected_sets:
        run(f"emerge @{s}", chroot=True)

def finalize_system():
    username = input("Enter your desired username: ").strip()
    timezone = input("Enter your timezone (e.g., Australia/Brisbane): ").strip()

    run(f"echo 'boringos' > /etc/hostname", chroot=True)
    run(f"ln -sf /usr/share/zoneinfo/{timezone} /etc/localtime", chroot=True)
    run("echo 'en_AU.UTF-8 UTF-8' > /etc/locale.gen", chroot=True)
    run("locale-gen", chroot=True)
    run("echo 'LANG=\"en_AU.UTF-8\"' > /etc/env.d/02locale", chroot=True)
    run("env-update && source /etc/profile", chroot=True)

    run(f"useradd -m -G wheel,audio,video,plugdev -s /bin/bash {username}", chroot=True)
    print(f"📛 Set password for {username}:")
    run(f"passwd {username}", chroot=True)

    run("emerge --quiet app-admin/sudo", chroot=True)
    run("echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel", chroot=True)

    run("systemctl enable NetworkManager", chroot=True)

def main():
    mount_chroot_env()
    install_kernel_and_bootloader()
    select_and_install_sets()
    finalize_system()

    print("🚀 boringOS setup complete. You can now exit chroot and reboot.")

if __name__ == "__main__":
    main()
