#!/usr/bin/env python3

import subprocess
import logging
import os
from datetime import datetime

LOGFILE = "/var/log/boringos-update.log"

logging.basicConfig(filename=LOGFILE, level=logging.INFO,
                    format="%(asctime)s %(levelname)s: %(message)s")

def run(cmd):
    logging.info(f"Running: {cmd}")
    try:
        subprocess.check_call(cmd, shell=True)
    except subprocess.CalledProcessError as e:
        logging.error(f"Command failed: {cmd} (exit {e.returncode})")
        raise

def main():
    logging.info("==== Starting boringOS update ====")

    # Sync portage tree
    run("emerge --sync")

    # World update
    run("emerge -uDNv --with-bdeps=y @world")

    # Rebuild modules
    run("emerge @module-rebuild")

    # Update preserved libraries
    run("emerge @preserved-rebuild")

    # Bootloader update (systemd-boot example)
    if os.path.exists("/usr/bin/bootctl"):
        run("bootctl update")

    # Kernel cleanup
    try:
        # Get running and latest installed kernel versions
        uname = subprocess.check_output("uname -r", shell=True).decode().strip()
        sources = [f.replace("linux-", "") for f in os.listdir("/usr/src") if f.startswith("linux-")]
        latest = sorted(sources)[-1] if sources else None
        keep = set([uname, latest])

        for k in sources:
            if k not in keep:
                logging.info(f"Removing old kernel: {k}")
                run(f"emerge -C =sys-kernel/gentoo-sources-{k}")
                run(f"rm -rf /lib/modules/{k} /boot/*{k}*")
    except Exception as ex:
        logging.error(f"Kernel cleanup failed: {ex}")

    logging.info("==== boringOS update complete ====")

if __name__ == "__main__":
    main()
