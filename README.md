# RouterInfo
Written specifically for https://www.instagram.com/natschooler/ 
# checkrouter.sh

A menu-driven bash tool for openSUSE Tumbleweed that:

- Looks up your router's/machine's public IP and geolocation via [ipinfo.io](https://ipinfo.io)
- Emails the report to a configurable list of recipients via `msmtp`
- Optionally sends a condensed summary as an SMS via a SIM900 GPRS module wired to an Arduino Uno

## Requirements

Installed automatically (with your permission) via `zypper` if missing:

- `curl` — fetches the geolocation data
- `jq` — parses the JSON response
- `msmtp` — sends the email

Also needed, but not auto-installed:

- A working `~/.msmtprc` (see [Email setup](#email-setup) below)
- For the SIM900 feature: the Arduino IDE, an Arduino Uno, and a SIM900 GPRS/GSM shield or breakout

## Quick start

```bash
chmod +x checkrouter.sh
./checkrouter.sh
```

You'll land on the main menu:

```
====================================
 Router Location Reporter
====================================

 1) Generate report and email it
 2) Generate report only
 3) Send last report again
 4) Manage recipients
 5) Gmail / msmtp setup instructions
 6) Check dependencies
 7) SIM900 GPRS / SMS (via Arduino USB)
 8) Exit
```

## Menu options

### 1) Generate report and email it
Runs the full pipeline: checks the OS, checks dependencies, fetches the location report, writes it to `~/location_report.txt`, and emails it to everyone in your recipients list.

### 2) Generate report only
Fetches and writes the report without sending any email. Useful for testing or if you just want to see the data.

### 3) Send last report again
Re-sends whatever is currently in `~/location_report.txt` without regenerating it. Handy if the report step succeeded but the email step failed and you don't want to re-query ipinfo.io.

### 4) Manage recipients
Opens a submenu to add or remove email addresses:

```
------------------------------------
 Manage Recipients
------------------------------------
Current recipients:
 1) someone@example.com

 a) Add recipient
 r) Remove recipient
 b) Back to main menu
```

- **Add** — prompts for an address, validates the format, and rejects duplicates.
- **Remove** — shows the numbered list and deletes the one you pick.

Recipients are stored one per line in `~/.checkrouter_recipients` (see [Files created](#files-created)). You can also edit that file directly with any text editor — lines starting with `#` are treated as comments and ignored.

### 5) Gmail / msmtp setup instructions
Prints step-by-step instructions for getting Gmail SMTP working with `msmtp`, with clickable links to the relevant Google account pages (see [Email setup](#email-setup) for the full walkthrough). It will also offer to open `~/.msmtprc` in your editor (`nano` by default, or whatever `$EDITOR` is set to) right from the menu.

### 6) Check dependencies
Manually re-runs the `curl` / `jq` / `msmtp` check and offers to install anything missing via `zypper`.

### 7) SIM900 GPRS / SMS (via Arduino USB)
Opens a submenu for sending a condensed version of the report as an SMS through a SIM900 module wired to an Arduino Uno, controlled over the Uno's USB serial connection. See [SIM900 / Arduino setup](#sim900--arduino-setup) below for full details.

### 8) Exit
Quits the script.

## Files created

All files live under your home directory:

| File | Purpose | Permissions |
|---|---|---|
| `~/location_report.txt` | The most recently generated report | default |
| `~/.checkrouter_recipients` | One email address per line; `#` = comment | `600` |
| `~/.checkrouter_sim900_phone` | Destination phone number for SMS alerts | `600` |
| `~/.msmtprc` | Gmail SMTP credentials for `msmtp` | should be `600` |
| `~/sim900_report_sender/sim900_report_sender.ino` | Generated Arduino sketch | default |

The recipients and phone number files are created automatically the first time you need them (with a template, in the case of the recipients file) — you never have to create them by hand.

## Email setup

Gmail requires an **App Password** rather than your normal account password when sending mail via SMTP from a script like `msmtp`. Menu option **5** walks you through this interactively, but the steps are:

### A. Confirm 2-Step Verification is on
Visit [myaccount.google.com/security](https://myaccount.google.com/security) and check that "2-Step Verification" says **On**. App Passwords don't exist until this is enabled.

### B. Generate a fresh App Password
Visit [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords), create one named `msmtp`, and copy it down **without spaces** — Google displays it in four groups of four characters, but `~/.msmtprc` needs it as one continuous string.

### C. Update `~/.msmtprc`

```
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/ca-bundle.pem
logfile        ~/.msmtp.log

account        default
host           smtp.gmail.com
port           587
from           your_gmail_address@gmail.com
user           your_gmail_address@gmail.com
password       your_16_char_app_password
```

Then lock the file down — it contains a plaintext credential:

```bash
chmod 600 ~/.msmtprc
```

### Testing it manually

Before relying on the script, confirm mail actually sends:

```bash
echo -e "Subject: test\n\nhello" | msmtp your_address@example.com
```

Common failure and its cause:

| Error | Likely cause |
|---|---|
| `account default not found: no configuration file available` | `~/.msmtprc` doesn't exist yet |
| `534-5.7.9 Application-specific password required` | You used your normal Gmail password instead of an App Password, or 2-Step Verification isn't actually on, or the App Password still has spaces in it |

## SIM900 / Arduino setup

This lets the script send a short SMS summary of the report (IP, city/region/country, coordinates) through a SIM900 GPRS/GSM module, using an Arduino Uno as a USB-to-GSM bridge.

### Why the Uno is wired this way

The Uno's hardware UART (pins 0/1) is the same connection used to talk to it over USB. If the SIM900 were wired to those same pins, uploading a new sketch and running the SMS relay would conflict. So the sketch instead uses a **software** serial port on pins 7/8 for the SIM900, leaving the hardware UART free for USB communication with this script.

### Wiring

| SIM900 pin | Arduino Uno pin |
|---|---|
| TX | 7 |
| RX | 8 |
| GND | GND |
| Power | Its own supply — **not** the Uno's 5V pin |

Two things worth being careful about:

- The SIM900 can draw current spikes of 2A+ while transmitting. Powering it from the Uno's 5V pin can brown out the board — give it its own supply.
- Many SIM900 boards run 3.3V logic. If yours does, put a voltage divider or logic-level shifter on the line going *into* the Arduino (SIM900 TX → Arduino pin 7) to avoid over-driving the input.

### Generating and uploading the sketch

From the SIM900 submenu (main menu → 7), choose **1) Generate Arduino sketch**. This writes:

```
~/sim900_report_sender/sim900_report_sender.ino
```

Open that folder in the Arduino IDE (the folder name matches the `.ino` filename, which the IDE requires) and upload it to your Uno as normal.

### Setting the destination number

Choose **2) Set/change destination phone number** from the SIM900 submenu. Enter it in international format, e.g. `+441234567890`. It's saved to `~/.checkrouter_sim900_phone`.

### Sending an SMS

Choose **3) Send report summary via SMS now**. The script will:

1. Auto-detect the Arduino on `/dev/ttyACM*` or `/dev/ttyUSB*` (if more than one matching device is present, it asks which one).
2. Load the saved phone number (or prompt you to set one if none exists yet).
3. Build a condensed summary from the last report — SMS length limits mean it sends `IP: ... City, Region, Country (lat,lon)` rather than the full report text.
4. Open the serial port at 9600 baud and send the protocol described below.
5. Wait up to 15 seconds for the Arduino to confirm the send, printing whatever it reports back.

### USB serial protocol

The script and sketch talk to each other over USB with simple newline-delimited text:

```
PHONE:+441234567890
<message line 1>
<message line 2>
...
###END###
```

The Arduino buffers everything between a `PHONE:` line and the `###END###` marker, then sends it as one SMS via `AT+CMGS` to the number given. It reports back over USB:

- `PHONE_SET:<number>` — acknowledges the phone number was received
- `SENDING_SMS` — about to issue the AT command sequence
- `SMS_DONE` — the module finished transmitting
- `ERROR:no phone or message set` — the end marker arrived with nothing to send

### Tuning notes

The delays baked into both the sketch and the script (SIM900 boot time, AT command turnaround, SMS transmit time) are reasonable starting points, not guarantees — timing varies by module firmware and signal conditions. If a send times out or the module doesn't respond:

- Increase the `delay()` values in the sketch's `setup()` and `sendSMS()` functions
- Increase the `sleep` values in `send_via_sim900()` in the script
- Check the SIM900 has a valid SIM card, sufficient signal, and is fully booted (its status LED behavior varies by board, but a steady fast blink usually means it's still searching for network)

## Troubleshooting

| Symptom | Check |
|---|---|
| "Missing packages detected" won't go away after install | Confirm `zypper install` actually completed without error; try `command -v curl jq msmtp` manually |
| Email always fails | Test `msmtp` directly (see [Testing it manually](#testing-it-manually)) before blaming the script |
| "No Arduino found on /dev/ttyACM* or /dev/ttyUSB*" | Check the USB cable (some are charge-only), confirm the sketch uploaded successfully, run `ls /dev/tty*` before and after plugging in to see what appears |
| SMS never arrives but script reports `SMS_DONE` | Check SIM balance/credit, signal strength, and that the number was entered in full international format |
 
