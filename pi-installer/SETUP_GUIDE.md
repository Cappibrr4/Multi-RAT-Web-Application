# Multi-RAT Pi Installer — Setup Guide
## From factory-new Pi to working installer

---

## PHASE 1 — Flash Ubuntu onto the Pi (on your laptop)

### What you need
- Raspberry Pi 5
- microSD card (16 GB minimum)
- Your laptop with Raspberry Pi Imager installed
- The Pi's power cable
- An ethernet cable

### Steps

1. Download and open **Raspberry Pi Imager**
   https://www.raspberrypi.com/software/

2. Click **Choose OS** → Other general-purpose OS → Ubuntu → **Ubuntu Server 22.04.x LTS (64-bit)**

3. Click the **⚙️ gear icon** (Advanced options) and set:
   - Hostname: `multirat-pi`
   - Enable SSH: ✓ (Use password authentication)
   - Username: `adil`
   - Password: _(choose something you'll remember)_
   - Configure WiFi: ✓ — enter your home/lab WiFi SSID + password
   - WiFi country: SG

4. Click **Write** and wait for it to finish.

5. Insert SD card into the Pi and power it on. Wait 60–90 seconds.

6. From your laptop terminal, SSH in:
   ```
   ssh adil@multirat-pi.local
   ```
   If `.local` doesn't resolve, find the Pi's IP from your router's device list and use that.

---

## PHASE 2 — Copy the installer onto the Pi (on your laptop)

### Step A — Pack the dashboard
On your laptop, in the project root:
```bash
bash pi-installer/pack_dashboard.sh
```
This creates `pi-installer/payloads/dashboard.tar.gz`.

### Step B — Add scheduler files (when ready)
Copy your novel MPTCP scheduler `.c` files into:
```
pi-installer/payloads/schedulers/
```
And the Makefile for building them. The installer will pick them up automatically.

### Step C — Copy everything to the Pi
```bash
scp -r pi-installer/ adil@multirat-pi.local:~/multirat-installer/
```

---

## PHASE 3 — Configure the Pi as the installer (SSH'd into Pi)

```bash
cd ~/multirat-installer
sudo bash setup_pi.sh
```

This takes ~2 minutes and:
- Sets the Pi's ethernet port to static IP `192.168.42.1`
- Starts a DHCP server (auto-gives target machine an IP when plugged in)
- Enables mDNS so Pi is reachable as `multirat-pi.local`
- Starts the web server on port 80 (auto-starts on every boot)

When it finishes, the Pi is ready. You can unplug it from your laptop.

---

## PHASE 4 — Using the installer on a target machine (at sea / in school)

1. **Plug an ethernet cable** from the Pi into the target machine's ethernet port.

2. **Power on the Pi** (USB-C power cable).

3. On the target machine, **open a browser** and go to:
   ```
   http://multirat-pi.local
   ```

4. The **setup menu** appears. Open a terminal on the target machine and run the command shown:
   ```bash
   curl http://multirat-pi.local/install.sh | sudo bash
   ```

5. Watch the progress live in the browser. Installation takes ~5–10 minutes.

6. When complete, open **http://localhost:3000** on the target machine — the dashboard is running.

---

## Notes

- **Novel MPTCP scheduler `.c` files** are already in `payloads/schedulers/` — the installer injects them into the kernel source automatically.
- **MPQUIC client/server Go files** are in `payloads/mpquic_clients/` and `payloads/mpquic_server/` — copied into mp-quic during install.
- **Kernel rebuild takes time** — the MPTCP schedulers require building the kernel from source (`mptcp_net-next`). This takes 30–90 minutes on the target machine. Internet is required for the first install to clone the kernel repo. After the build, the machine reboots into the new kernel.
- **Go tarball (offline)**: download `go1.20.14.linux-amd64.tar.gz` from go.dev and drop it into `payloads/` on the Pi. The installer will use it instead of downloading from the internet.
- **mp-quic offline**: pre-clone the repo (`git clone https://github.com/qdeconinck/mp-quic.git`), tar it (`tar -czf payloads/mp-quic.tar.gz -C mp-quic .`), and copy to Pi payloads. The installer uses it instead of cloning.
- **Pi OS vs Ubuntu**: The Pi itself just needs to run any Linux with Python 3. The Pi does NOT need MPTCP — it's just the installer. MPTCP goes on the target machine.
- **After reboot**: once the target machine reboots, run `curl http://multirat-pi.local/check.sh | bash` to verify all schedulers loaded correctly.
