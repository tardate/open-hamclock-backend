# 🛟  📡 OHB — Open HamClock Backend

When the original backend went dark, the clocks didn’t have to. 

## Overview
Mitigates centralized backend risk by enabling deployment across multiple independent, federated instances. Continuity is guaranteed since OHB is open source and easily maintained.

🧱 Open-source, self-hostable backend replacement for HamClock — restoring live propagation data, maps, and feeds.

The software is free to use and download. We do not take donations.

OHB currently proxies VOACAP and PSKReporter. All other feeds and maps are generated locally. Backend selection always remains user-controlled - no lock in to OHB if you change your mind.

## What's a "backend"? 

It is how HamClock got all of its data. Without a separate backend, all HamClock's will cease to function by June 2026.

Drop-in compatible with existing HamClock's — no firmware changes required.

OHB provides faithful replacements for the data feeds and map assets
that HamClock depends on — built by operators, for operators.

All maps are generated on your own self hosted hardware. VOACAP is in work. 

> This project is not affiliated with HamClock or its creator,
> Elwood Downey, WB0OEW.
> We extend our sincere condolences to the Downey family.

## ⚙️ What OHB Does

- Implements a self-hosted backend compatible with the HamClock backend interface
- Rebuilds HamClock dynamic text feeds (solar, geomag, DRAP, PSK, RBN, WSPR, Amateur Satellites, DxNews, Contests, etc) all on your own hardware
- Generates faithful HamClock-style map overlays (MUF-RT, DRAP, Aurora, Wx-mB, etc.) Note: Maps may vary slightly due to upstream model differences
- Produces zlib-compressed BMP assets in multiple resolutions using the same specialized, RGB top down approach that is required by HamClock
- Designed for Raspberry Pi, cloud, or on-prem deployment
- Fully open source and community maintained
- Auto log rotation
- Command and Control Dashboard (future)
- Runs in Raspberry Pi 4, 5, PC, Virtual Machine, Bare Metal or Cloud
  
## 🧱 OHB Central Server (testing)
These steps let you point a HamClock (or any client) at a shared OHB test server without self-hosting. This is a local-only change on your machine and is easy to revert.

This is a test server and may be subject to unannounced or unplanned updates. 

Important: Editing your hosts file overrides normal DNS for the specified hostname. After this change, anything on this computer that connects to clearskyinstitute.com will go to the OHB test server instead.

### /etc/hosts file modification
These steps will tell your system to not use clearskyinstitute.com if you do not use the -b option for local install. For now, **do not** use this option if you are self-hosting. This is a semi-permanent change.

```sudo nano /etc/hosts```

Add this line:

```44.32.64.64     clearskyinstitute.com```

Save the file with CTRL+X

Next, verify it is in effect

```getent hosts clearskyinstitute.com```

It should return

```44.32.64.64     clearskyinstitute.com```

Finally, you should be able to ping the re-directed host

```ping -c 5 clearskyinstitute.com```

It should say 100% and you should be able to restart your hamclock to connect to ohb.hamclock.app.

### -b option

HamClock version 4.22 has been tested with the -b option. You can connect without modifying your /etc/hosts file. This will allow you to switch between different backends and is the easiest option for most people. 

In the directory where hamclock is installed, 

```./hamclock -b ohb.hamclock.app:80```

If unsure, you can type

``which hamclock``

and if hamclock is installed in your PATH on the system then it will tell you where the application is installed. From there, you can type the path to hamclock

``/path/to/hamclock -b ohb.hamclock.app:80``

/path/to/hamclock may vary on your system

### Transitioning? Be sure to clear your .hamclock cache
For users transitioning immediately from ClearSkyInstitute or another backend server, it is important that you clear these two file types to ensure you pull latest upon connecting to either your local backend or the central backend. This involves deleting *.bmp and *.txt from your .hamclock cache directory. Do not delete the eeprom file or you will lose your settings. 
```
rm /root/.hamclock/*.bmp /root/.hamclock/*.txt
rm /home/*/.hamclock/*.txt /home/*/.hamclock/*.bmp
```

## 🧭 Architecture
```
[ NOAA / KC2G / PSK / SWPC ]
              |
              v
        +-------------+
        |     OHB     |
        |-------------|
        | Python/Perl|
        | GMT/Maps   |
        | Cron Jobs  |
        +-------------+
              |
           HTTP/ZLIB
              |
         +----------+
         | lighttpd |
         +----------+
              |
         +----------+
         | HamClock |
         +----------+
```
## Compatibility 👉 [Compatibility](COMPATIBILITY.md)
## 💬 Join us on Discord
We are building a community-powered backend to keep HamClock running. \
Discord is where we can collaborate, troubleshoot, and exchange ideas — no RF license required 😎 \
https://discord.gg/wb8ATjVn6M

# OHB in Production (Live HamClock Clients)

## Automatic AMSAT Satellite Updater Backend - Keep Your Satellites Fresh!

Note: This will only list **ACTIVE** AMSAT satellites from the AMSAT Status Page.

<img width="795" height="459" alt="image" src="https://github.com/user-attachments/assets/47ee3b6f-2075-42e2-a55f-618a0fb9fad5" />
<img width="798" height="568" alt="image" src="https://github.com/user-attachments/assets/14b24350-c0a5-4b00-a36f-9c34c74fef3d" />
<img width="799" height="568" alt="image" src="https://github.com/user-attachments/assets/f10d67f5-186c-43b6-b9d9-71149fd897f7" />
<img width="804" height="482" alt="image" src="https://github.com/user-attachments/assets/e1778c0e-e22c-4a42-8e50-789b1bc85692" />
<img width="797" height="569" alt="image" src="https://github.com/user-attachments/assets/35e843bf-f2c6-4b99-881b-1bf675660b7a" />
<img width="797" height="571" alt="image" src="https://github.com/user-attachments/assets/859d158c-e441-4788-bd67-3aaa48be45e0" />
<img width="801" height="480" alt="image" src="https://github.com/user-attachments/assets/8313d34e-e71c-4455-98c4-7f204d3ac59f" />
<img width="805" height="486" alt="image" src="https://github.com/user-attachments/assets/c59d485f-08ed-4bf6-85e1-aed5e4a6cabe" />
<img width="822" height="505" alt="image" src="https://github.com/user-attachments/assets/0a0b8c73-293e-4723-a8ba-c32abdfa7bdd" />
<img width="803" height="487" alt="image" src="https://github.com/user-attachments/assets/c507f348-bdda-4683-9473-796545067e0e" />
<img width="816" height="490" alt="image" src="https://github.com/user-attachments/assets/99582cf9-9a89-4a37-ba31-7996156d2fc7" />

## 🚀 Quick Start 👉 [Quick Start Guide](QUICK_START.md)
## 📦 Installation 👉 [Detailed installation instructions](INSTALL.md)
## 📊 Project Completion Status

OHB targets ~40+ HamClock artifacts (feeds, maps, and endpoints).

As of today:

- All core dynamic maps implemented
- All text feeds replicated
- Amateur satellites with fresh TLEs
- RSS feed works for thousands for clients
- Integration-tested on live HamClock clients
- Remaining work focused on VOACAP + RBN endpoints  

👉 Full artifact tracking and integration status:
[PROJECT_STATUS.md](PROJECT_STATUS.md) 
## 📚 Data Attribution 👉 [Attribution](ATTRIBUTION.md)
## 🤝 Contributing
Bug reports and pull requests are welcome on GitHub at
https://github.com/BrianWilkinsFL/open-hamclock-backend/issues
## 📄 Disclaimer 👉 [Disclaimer](./DISCLAIMER.md)
## Related
- [ohb-pskreporter-proxy](https://github.com/BrianWilkinsFL/ohb-pskreporter-proxy)
- [hamclock-proxy-lite](https://github.com/BrianWilkinsFL/hamclock-proxy-lite)
- [HamClockLauncher](https://github.com/huberthickman/HamClockLauncher)
