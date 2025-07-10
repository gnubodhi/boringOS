#!/usr/bin/env python3

import subprocess
import os
import sys
import shutil

def run(cmd, check=True):
    print(f"📦 Running: {cmd}")
    subprocess.run(cmd, shell=True, check=check)

def prompt_hostname():
    hostname = input("🖥️ Enter your desired hostname: ").strip()
    if hostname:
        with open("/etc/hostname", "w") as f:
            f.write(f"{hostname}\n")
        print(f"✅ Hostname set to {hostname}")
    else:
        print("⚠️ No hostname entered. Skipping...")

def prompt_timezone():
    tz = input("🌍 Enter your timezone (e.g., Australia/Brisbane): ").strip()
    tz_path = f"/usr/share/zoneinfo/{tz}"
    if os.path.exists(tz_path):
        if os.path.exists("/etc/localtime"):
            os.remove("/etc/localtime")
        os.symlink(tz_path, "/etc/localtime")
        print(f"✅ Timezone set to {tz}")
    else:
        print("❌ Invalid timezone path.")

def configure_locales():
    print("🌐 Configuring locales...")
    default_locale = "en_AU.UTF-8 UTF-8"
    locale_conf = "en_AU.UTF-8"

    # Ensure locale.gen includes the locale
    with open("/etc/locale.gen", "a+") as f:
        f.seek(0)
        if default_locale not in f.read():
            f.write(f"{default_locale}\n")

    run("locale-gen")
    with open("/etc/default/locale", "w") as f:
        f.write(f"LANG={locale_conf}\n")
    print("✅ Locales configured.")

def install_base_tools():
    print("🛠️ Installing base system tools...")
    run("apt update && apt upgrade -y")
    run("apt install -y linux-image-generic grub2 systemd network-manager sudo")

def enable_services():
    print("🚀 Enabling NetworkManager...")
    run("systemctl enable NetworkManager")

def install_grub():
    print("🧹 Installing GRUB bootloader...")
    run("grub-install --target=i386-pc --recheck /dev/sda")

def generate_fstab():
    print("📝 Generating /etc/fstab...")
    run("genfstab -U / > /etc/fstab")

def set_root_password():
    print("🔐 Please set the root password:")
    run("passwd")

def configure_grub_entry():
    print("📂 Configuring GRUB bootloader entry...")

    grub_cfg_path = "/etc/grub.d/40_custom"
    
    with open(grub_cfg_path, "a") as f:
        f.write("""\
menuentry 'Ubuntu' {
    set root=(hd0,1)
    linux /boot/vmlinuz root=UUID=$(blkid -s UUID -o value /dev/sda1) ro
    initrd /boot/initrd.img
}
""")
    run("update-grub")
    print(f"✅ Updated GRUB configuration at {grub_cfg_path}")

def main():
    prompt_hostname()
    prompt_timezone()
    configure_locales()
    install_base_tools()
    enable_services()
    install_grub()
    generate_fstab()
    set_root_password()
    configure_grub_entry()

    print("🎉 Ubuntu setup complete. You can now exit the chroot and reboot.")

if __name__ == "__main__":
    if os.geteuid() != 0:
        print("❌ Please run this script as root inside the chroot environment.")
        sys.exit(1)
    main()
