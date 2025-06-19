#!/bin/bash

set -e

echo "🧽 Welcome to boringOS setup wizard"
echo "This tool will help you prepare a disk for installation."
echo "Bored?"
echo

# Step 1: List block devices (excluding loop and removable media)
echo "📦 Detected Drives:"
lsblk -dpno NAME,SIZE,MODEL,TYPE | grep -v 'loop\|sr\|zram'

# Step 2: Select the first eligible drive (non-removable)
DEFAULT_DRIVE=$(lsblk -dpno NAME,TYPE | grep -E 'disk' | head -n 1 | awk '{print $1}')

echo
echo "👉 Default drive candidate: $DEFAULT_DRIVE"
read -rp "Can I format this drive for boringOS? [y/N] " CONFIRM

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "🧨 WARNING: All data on $DEFAULT_DRIVE will be lost."
    read -rp "Are you REALLY sure you want to format $DEFAULT_DRIVE? [yes/N] " FINAL_CONFIRM

    if [[ "$FINAL_CONFIRM" == "yes" ]]; then
        echo "⚙️ Formatting $DEFAULT_DRIVE..."

        # Optional: unmount anything mounted on the drive
        sudo umount "${DEFAULT_DRIVE}"* || true

        # Step 3: Create partitions (UEFI + root)
        sudo parted --script "$DEFAULT_DRIVE" \
            mklabel gpt \
            mkpart ESP fat32 1MiB 513MiB \
            set 1 boot on \
            mkpart primary ext4 513MiB 100%

        # Reload partition table
        echo "🔄 Reloading partition table..."
        sudo partprobe "$DEFAULT_DRIVE"
        sleep 2

        # Step 4: Format partitions
        EFI_PART="${DEFAULT_DRIVE}1"
        ROOT_PART="${DEFAULT_DRIVE}2"

        sudo mkfs.vfat -F32 "$EFI_PART"
        sudo mkfs.ext4 -F "$ROOT_PART"

        echo "✅ $DEFAULT_DRIVE has been formatted with EFI and root partitions."

        # Step 5: Mount root and create swap
        MOUNT_DIR="/mnt/boringos"
        sudo mkdir -p "$MOUNT_DIR"
        sudo mount "$ROOT_PART" "$MOUNT_DIR"
        sudo mkdir -p "$MOUNT_DIR/boot"
        sudo mount "$EFI_PART" "$MOUNT_DIR/boot"

        echo
        read -rp "Would you like to create a swap file? [Y/n] " CREATE_SWAP
        if [[ "$CREATE_SWAP" =~ ^[Yy]$ || -z "$CREATE_SWAP" ]]; then
            echo "📦 Creating 4GB swap file..."
            sudo fallocate -l 4G "$MOUNT_DIR/swapfile"
            sudo chmod 600 "$MOUNT_DIR/swapfile"
            sudo mkswap "$MOUNT_DIR/swapfile"
            sudo swapon "$MOUNT_DIR/swapfile"
            echo "/swapfile none swap sw 0 0" | sudo tee -a "$MOUNT_DIR/etc/fstab"
            echo "✅ Swap file created and activated."
        else
            echo "🚫 Skipping swap file creation."
        fi

        echo
        echo "🌐 boringOS will now download the Gentoo stage3 tarball and begin setup."
        echo "⚠️  You may optionally add a package repository, but I am not responsible for those packages. Be warned."

        # Step 6: Download and extract stage3
STAGE3_URL="https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/current-stage3-amd64/systemd/stage3-amd64-systemd.tar.xz"
STAGE3_TARBALL="stage3-amd64-systemd.tar.xz"

wget "$STAGE3_URL" -O "$STAGE3_TARBALL"
sudo tar xpf "$STAGE3_TARBALL" -C "$MOUNT_DIR" --xattrs-include='*.*' --numeric-owner

# Copy Git-based Portage configuration
echo "📁 Applying Git-based Portage configuration..."
sudo mkdir -p "$MOUNT_DIR/etc/portage/repos.conf"
sudo cp ./etc/portage/repos.conf/gentoo.conf "$MOUNT_DIR/etc/portage/repos.conf/"

echo "✅ Stage3 tarball extracted."

        # Step 7: Prepare for chroot
        sudo mount --types proc /proc "$MOUNT_DIR/proc"
        sudo mount --rbind /sys "$MOUNT_DIR/sys"
        sudo mount --make-rslave "$MOUNT_DIR/sys"
        sudo mount --rbind /dev "$MOUNT_DIR/dev"
        sudo mount --make-rslave "$MOUNT_DIR/dev"

        echo
        echo "..still no package repo support. One day? Nah. Submit a patch. I'm a reasonable person."
echo "🛠️  Time to chroot and compile. Boring is a feature, not a bug."

        sudo chroot "$MOUNT_DIR" /bin/bash <<EOF
source /etc/profile
echo "📦 Syncing Portage..."
emerge --sync

# Placeholder for building tools and kernel
# Install kernel and bootloader
echo "📦 Installing gentoo-kernel-bin and systemd-boot..."
emerge gentoo-kernel-bin systemd-boot
bootctl --path=/boot install
echo "🧠 Compiling core toolsets: LLVM, Clang, Boost, ROCm..."
emerge --update --deep --newuse @world

# Install core toolset set
echo "📦 Installing core boringOS tools set..."
emerge @boringos-tools
EOF

    else
        echo "❌ Cancelled. No formatting performed."
        exit 1
    fi
else
    echo
    echo "🧭 No problem. You can format your drive manually using the built-in tools."

    echo
    echo "Launching cfdisk for manual partitioning..."
    read -rp "Enter the drive you want to partition (e.g., /dev/sda): " CUSTOM_DRIVE

    if [[ -b "$CUSTOM_DRIVE" ]]; then
        sudo cfdisk "$CUSTOM_DRIVE"
    else
        echo "🚫 Invalid device."
        exit 1
    fi
fi
