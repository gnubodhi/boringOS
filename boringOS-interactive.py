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
    with open("/etc/locale.conf", "w") as f:
        f.write(f"LANG={locale_conf}\n")
    print("✅ Locales configured.")

def install_base_tools():
    print("🛠️ Installing base system tools...")
    run("emerge -avuDN --with-bdeps=y @world")
    run("emerge --noreplace gentoo-kernel systemd-boot networkmanager arch-install-scripts sudo")

def enable_services():
    print("🚀 Enabling NetworkManager...")
    run("systemctl enable NetworkManager")

def install_systemd_boot():
    print("🧹 Installing systemd-boot...")
    run("bootctl install")

def generate_fstab():
    print("📝 Generating /etc/fstab...")
    run("genfstab -U / > /etc/fstab")

def set_root_password():
    print("🔐 Please set the root password:")
    run("passwd")

def configure_bootloader_entry():
    print("📂 Checking systemd-boot loader entries...")

    loader_dir = "/boot/loader/entries"
    os.makedirs(loader_dir, exist_ok=True)

    boot_entry_path = os.path.join(loader_dir, "boringos.conf")

    if not os.path.exists(boot_entry_path):
        print("📄 Creating systemd-boot entry...")

        blkid_output = subprocess.check_output("blkid", text=True)
        root_uuid = None
        for line in blkid_output.splitlines():
            if "ext4" in line and "UUID=" in line:
                parts = line.split()
                for part in parts:
                    if part.startswith("UUID="):
                        root_uuid = part.split("=")[1].strip('"')
                        break
            if root_uuid:
                break

        if not root_uuid:
            print("❌ Could not detect root UUID automatically. Please edit /boot/loader/entries manually.")
            return

        with open(boot_entry_path, "w") as f:
            f.write(f"""\
title   boringOS
linux   /vmlinuz
initrd  /initramfs
options root=UUID={root_uuid} rw
""")
        print(f"✅ Created boot entry: {boot_entry_path}")
    else:
        print("✅ systemd-boot entry already exists.")

def main():
    prompt_hostname()
    prompt_timezone()
    configure_locales()
    install_base_tools()
    enable_services()
    install_systemd_boot()
    generate_fstab()
    set_root_password()
    configure_bootloader_entry()

    print("🎉 boringOS setup complete. You can now exit the chroot and reboot.")

if __name__ == "__main__":
    if os.geteuid() != 0:
        print("❌ Please run this script as root inside the chroot environment.")
        sys.exit(1)
    main()
