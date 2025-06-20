Why Python for everything?
Python is the language I’m currently learning, so it’s what I use. If you’d prefer Rust, Go, C, or anything else, feel free to fork and rewrite it — and I’ll happily cheer you on! Who knows, I might even switch to your version one day, especially if you’re keen to take on the maintenance burden (and send boringOS into a well-earned dormancy). If I ever retire the project, I may even grant you use of the copyright — as long as your project remains in the same spirit and follows the ethics document.

Why MIT?
Well, ChatGPT gave me the code freely to use as I please, so MIT felt like a natural fit. I wanted others to have the same freedom with boringOS — use it, modify it, share it, no strings attached (other than a nod to the ethics doc and a bit of credit where it’s due).

Q: This project includes external package installers. Should I trust you?
A: Only if you’re comfortable with the risks! If you don’t trust me to provide packages, you definitely shouldn’t make this script executable or run it.

Will the updater run by default?
Nope. For safety and transparency, nothing is automated until you set it up yourself.

You have to make the Python script executable (chmod +x /usr/local/bin/boringos-update.py).

Then, you choose if and when to enable the systemd timer/service (systemctl enable --now boringos-update.timer).

This means:

Nothing will update your system behind your back.

The updater is there if you want it — and if you trust it.

If you don’t want it, just leave it disabled or delete it.

Want to inspect or modify it before enabling? Go ahead — it’s your system.
