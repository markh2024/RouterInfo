#!/bin/bash
#
# location_report.sh
#
# Menu-driven router/IP location report using ipinfo.io
# openSUSE Tumbleweed
#

set -e

#############################################
# Configuration
#############################################

RECIPIENTS_FILE="$HOME/.checkrouter_recipients"
MSMTP_CONF="$HOME/.msmtprc"
REPORT="$HOME/location_report.txt"

SIM900_PHONE_FILE="$HOME/.checkrouter_sim900_phone"
SIM900_RECIPIENTS_FILE="$HOME/.checkrouter_sim900_recipients"
ARDUINO_SKETCH_DIR="$HOME/sim900_report_sender"
ARDUINO_SKETCH_FILE="$ARDUINO_SKETCH_DIR/sim900_report_sender.ino"
SIM900_BAUD=9600


#############################################
# Terminal hyperlink helper
#############################################
#
# Prints a clickable link using OSC 8 escape codes.
# Supported by GNOME Terminal, Konsole, iTerm2, kitty, etc.
# Terminals without support just show the plain text.

hyperlink()
{
    local URL="$1"
    local TEXT="$2"

    printf '\e]8;;%s\e\\%s\e]8;;\e\\\n' "$URL" "$TEXT"
}


#############################################
# Dependency checker
#############################################

check_dependencies()
{

    REQUIRED_PACKAGES=(
        curl
        jq
        msmtp
    )

    MISSING=()

    echo "Checking required packages..."

    for PACKAGE in "${REQUIRED_PACKAGES[@]}"
    do
        if ! command -v "$PACKAGE" >/dev/null 2>&1
        then
            MISSING+=("$PACKAGE")
        fi
    done


    if [ ${#MISSING[@]} -ne 0 ]
    then

        echo
        echo "Missing packages detected:"

        for ITEM in "${MISSING[@]}"
        do
            echo " - $ITEM"
        done


        echo
        read -p "Install missing packages? (y/n): " INSTALL


        if [[ "$INSTALL" == "y" ]]
        then

            echo "Updating repositories..."

            sudo zypper refresh


            echo "Installing packages..."

            sudo zypper install -y "${MISSING[@]}"


            echo "Installation complete."

        else

            echo "Cannot continue without dependencies."
            return 1

        fi

    else

        echo "All dependencies present."

    fi

}


#############################################
# Check operating system
#############################################

check_os()
{

    if [ -f /etc/os-release ]
    then

        source /etc/os-release

        echo "Detected:"
        echo "$NAME"

    else

        echo "Cannot detect operating system."
        return 1

    fi

}


#############################################
# Generate location report
#############################################

create_report()
{

echo "Obtaining IP location..."

DATA=$(curl -s https://ipinfo.io)


IP=$(echo "$DATA" | jq -r '.ip')
CITY=$(echo "$DATA" | jq -r '.city')
REGION=$(echo "$DATA" | jq -r '.region')
COUNTRY=$(echo "$DATA" | jq -r '.country')
ORG=$(echo "$DATA" | jq -r '.org')
LOC=$(echo "$DATA" | jq -r '.loc')


LAT=$(echo "$LOC" | cut -d',' -f1)
LON=$(echo "$LOC" | cut -d',' -f2)


cat > "$REPORT" <<EOF

====================================
 Router Location Report
====================================

Date:
$(date)


Public IP:
$IP


Internet Provider:
$ORG


Location:
$CITY
$REGION
$COUNTRY


Coordinates:

Latitude :
$LAT

Longitude:
$LON


Map:

https://maps.google.com/?q=$LAT,$LON


====================================

EOF


echo
cat "$REPORT"
echo
echo "Report written to:"
echo "  $REPORT"

if [ -f "$REPORT" ]
then
    echo "Report size: $(wc -c < "$REPORT") bytes"
else
    echo "ERROR: Report was not created!"
fi


}


#############################################
# Recipients management (email and/or SMS)
#############################################
#
# Each line in RECIPIENTS_FILE is: email|phone
# Either side can be blank (email-only or SMS-only recipient),
# but not both.

is_valid_email()
{
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}


is_valid_phone()
{
    [[ "$1" =~ ^\+[0-9]{7,15}$ ]]
}


ensure_recipients_file()
{

    if [ ! -f "$RECIPIENTS_FILE" ]
    then

        cat > "$RECIPIENTS_FILE" <<EOF
# One recipient per line, formatted as: email|phone
# Leave the phone blank for an email-only recipient (e.g. "someone@example.com|")
# or the email blank for an SMS-only recipient (e.g. "|+441234567890").
# Lines starting with # are ignored.
EOF

        chmod 600 "$RECIPIENTS_FILE"

    fi

    # Migrate a plain email-per-line file from an older version of this script.
    if grep -qv '^\s*#\|^\s*$\|.*|.*' "$RECIPIENTS_FILE" 2>/dev/null
    then
        local TMP
        TMP="$(mktemp)"

        while IFS= read -r LINE
        do
            if [[ "$LINE" == \#* ]] || [ -z "$(echo "$LINE" | xargs)" ] || [[ "$LINE" == *"|"* ]]
            then
                echo "$LINE" >> "$TMP"
            else
                echo "$(echo "$LINE" | xargs)|" >> "$TMP"
            fi
        done < "$RECIPIENTS_FILE"

        mv "$TMP" "$RECIPIENTS_FILE"
    fi

    # Migrate phone numbers from the old SMS-only recipients file, if present.
    if [ -f "$SIM900_RECIPIENTS_FILE" ]
    then
        while IFS= read -r LINE
        do
            LINE="$(echo "$LINE" | xargs)"
            if [ -z "$LINE" ] || [[ "$LINE" == \#* ]]
            then
                continue
            fi
            if ! grep -qF "|$LINE" "$RECIPIENTS_FILE" 2>/dev/null
            then
                echo "|$LINE" >> "$RECIPIENTS_FILE"
            fi
        done < "$SIM900_RECIPIENTS_FILE"
        rm -f "$SIM900_RECIPIENTS_FILE"
    fi

    # Migrate a number saved by the original single-destination version.
    if [ -f "$SIM900_PHONE_FILE" ]
    then
        local EXISTING_NUM
        EXISTING_NUM="$(cat "$SIM900_PHONE_FILE" 2>/dev/null | xargs)"
        if [ -n "$EXISTING_NUM" ] && ! grep -qF "|$EXISTING_NUM" "$RECIPIENTS_FILE" 2>/dev/null
        then
            echo "|$EXISTING_NUM" >> "$RECIPIENTS_FILE"
        fi
        rm -f "$SIM900_PHONE_FILE"
    fi

}


load_recipients()
{

    ensure_recipients_file

    RECIP_EMAILS=()
    RECIP_PHONES=()

    while IFS= read -r LINE
    do

        local RAW
        RAW="$(echo "$LINE" | xargs)"

        if [ -z "$RAW" ] || [[ "$RAW" == \#* ]]
        then
            continue
        fi

        local EMAIL="${LINE%%|*}"
        local PHONE=""

        if [[ "$LINE" == *"|"* ]]
        then
            PHONE="${LINE#*|}"
        fi

        EMAIL="$(echo "$EMAIL" | xargs)"
        PHONE="$(echo "$PHONE" | xargs)"

        RECIP_EMAILS+=("$EMAIL")
        RECIP_PHONES+=("$PHONE")

    done < "$RECIPIENTS_FILE"

}


list_recipients()
{

    load_recipients

    if [ ${#RECIP_EMAILS[@]} -eq 0 ]
    then
        echo "No recipients configured yet."
        return 0
    fi

    echo "Current recipients:"

    local I=1
    local N=${#RECIP_EMAILS[@]}

    while [ "$I" -le "$N" ]
    do

        local EMAIL="${RECIP_EMAILS[$((I - 1))]}"
        local PHONE="${RECIP_PHONES[$((I - 1))]}"
        local DESC

        if [ -n "$EMAIL" ] && [ -n "$PHONE" ]
        then
            DESC="$EMAIL | $PHONE"
        elif [ -n "$EMAIL" ]
        then
            DESC="$EMAIL"
        else
            DESC="SMS: $PHONE"
        fi

        echo " $I) $DESC"
        I=$((I + 1))

    done

}


add_recipient()
{

    ensure_recipients_file

    echo
    read -p "Enter email address (blank to skip): " NEW_EMAIL
    NEW_EMAIL="$(echo "$NEW_EMAIL" | xargs)"

    read -p "Enter phone number, international format (blank to skip): " NEW_PHONE
    NEW_PHONE="$(echo "$NEW_PHONE" | xargs)"

    if [ -z "$NEW_EMAIL" ] && [ -z "$NEW_PHONE" ]
    then
        echo "Cancelled — enter an email, a phone number, or both."
        return 0
    fi

    if [ -n "$NEW_EMAIL" ] && ! is_valid_email "$NEW_EMAIL"
    then
        echo "That doesn't look like a valid email address. Nothing added."
        return 1
    fi

    if [ -n "$NEW_PHONE" ] && ! is_valid_phone "$NEW_PHONE"
    then
        echo "That doesn't look like a valid international phone number (expected +<country code><number>). Nothing added."
        return 1
    fi

    load_recipients

    local I=0
    local N=${#RECIP_EMAILS[@]}

    while [ "$I" -lt "$N" ]
    do

        if [ -n "$NEW_EMAIL" ] && [ "${RECIP_EMAILS[$I]}" == "$NEW_EMAIL" ]
        then
            echo "$NEW_EMAIL is already in the list."
            return 0
        fi

        if [ -n "$NEW_PHONE" ] && [ "${RECIP_PHONES[$I]}" == "$NEW_PHONE" ]
        then
            echo "$NEW_PHONE is already in the list."
            return 0
        fi

        I=$((I + 1))

    done

    echo "${NEW_EMAIL}|${NEW_PHONE}" >> "$RECIPIENTS_FILE"

    if [ -n "$NEW_EMAIL" ] && [ -n "$NEW_PHONE" ]
    then
        echo "Added $NEW_EMAIL | $NEW_PHONE."
    elif [ -n "$NEW_EMAIL" ]
    then
        echo "Added $NEW_EMAIL."
    else
        echo "Added $NEW_PHONE."
    fi

}


remove_recipient()
{

    load_recipients

    if [ ${#RECIP_EMAILS[@]} -eq 0 ]
    then
        echo "No recipients to remove."
        return 0
    fi

    list_recipients

    echo
    read -p "Enter the number to remove (blank to cancel): " NUM

    if [ -z "$NUM" ]
    then
        echo "Cancelled."
        return 0
    fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#RECIP_EMAILS[@]} ]
    then
        echo "Invalid selection."
        return 1
    fi

    local IDX=$((NUM - 1))
    local TARGET_LINE="${RECIP_EMAILS[$IDX]}|${RECIP_PHONES[$IDX]}"

    grep -vFx "$TARGET_LINE" "$RECIPIENTS_FILE" > "$RECIPIENTS_FILE.tmp" || true
    mv "$RECIPIENTS_FILE.tmp" "$RECIPIENTS_FILE"

    echo "Removed $TARGET_LINE."

}


manage_recipients_menu()
{

    while true
    do

        echo
        echo "------------------------------------"
        echo " Manage Recipients (email and SMS)"
        echo "------------------------------------"
        list_recipients
        echo
        echo " a) Add recipient"
        echo " r) Remove recipient"
        echo " b) Back to main menu"
        echo

        read -p "Choose an option: " CHOICE

        case "$CHOICE" in
            a) add_recipient ;;
            r) remove_recipient ;;
            b) break ;;
            *) echo "Invalid option." ;;
        esac

    done

}


#############################################
# Send email

#############################################

send_email()
{
    load_recipients

    EMAIL_RECIPIENTS=()

    for EMAIL in "${RECIP_EMAILS[@]}"
    do
        if [ -n "$EMAIL" ]
        then
            EMAIL_RECIPIENTS+=("$EMAIL")
        fi
    done

    if [ ${#EMAIL_RECIPIENTS[@]} -eq 0 ]
    then
        echo "No email recipients configured."
        return 1
    fi

    if [ ! -f "$REPORT" ]
    then
        echo "No report found yet — generate one first."
        return 1
    fi

    echo "Emailing report to:"
    printf "  %s\n" "${EMAIL_RECIPIENTS[@]}"

    FAILED=()

    for ADDRESS in "${EMAIL_RECIPIENTS[@]}"
    do
        if msmtp "$ADDRESS" <<EOF
Subject: Router Location Report

$(cat "$REPORT")
EOF
        then
            echo "Sent to $ADDRESS"
        else
            echo "FAILED: $ADDRESS"
            FAILED+=("$ADDRESS")
        fi
    done

    if [ ${#FAILED[@]} -ne 0 ]
    then
        echo
        echo "Some emails failed:"
        printf "  %s\n" "${FAILED[@]}"
        return 1
    fi

    echo "All emails sent successfully."
}

#############################################
# Gmail / msmtp setup instructions
#############################################

show_gmail_setup_info()
{

    echo
    echo "===================================="
    echo " Gmail SMTP Setup (for msmtp)"
    echo "===================================="
    echo
    echo "A. Confirm 2-Step Verification is on"
    echo "   Check that '2-Step Verification' says On."
    hyperlink "https://myaccount.google.com/security" "https://myaccount.google.com/security"
    echo
    echo "B. Generate a fresh App Password"
    echo "   Create one named 'msmtp' and copy it without spaces."
    hyperlink "https://myaccount.google.com/apppasswords" "https://myaccount.google.com/apppasswords"
    echo
    echo "C. Update $MSMTP_CONF"
    echo "   It should look like:"
    echo
    cat <<'CONF'
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
CONF
    echo
    echo "   Remember: chmod 600 $MSMTP_CONF"
    echo
    echo "Test with:"
    echo "   echo -e \"Subject: test\\n\\nhello\" | msmtp your_address@example.com"
    echo

    if [ -f "$MSMTP_CONF" ]
    then
        read -p "Open $MSMTP_CONF in an editor now? (y/n): " EDIT_NOW
        if [[ "$EDIT_NOW" == "y" ]]
        then
            "${EDITOR:-nano}" "$MSMTP_CONF"
        fi
    else
        read -p "$MSMTP_CONF doesn't exist yet — create and open it now? (y/n): " CREATE_NOW
        if [[ "$CREATE_NOW" == "y" ]]
        then
            touch "$MSMTP_CONF"
            chmod 600 "$MSMTP_CONF"
            "${EDITOR:-nano}" "$MSMTP_CONF"
        fi
    fi

}


#############################################
# SIM900 / Arduino Uno SMS relay
#############################################
#
# The Uno's hardware serial (pins 0/1, same lines used by the USB
# port) talks to this script over USB. A SoftwareSerial pair on
# pins 7 (RX) and 8 (TX) talks to the SIM900 module, so uploading
# new sketches and running the relay never conflict with each other.
#
# Protocol spoken over USB serial (9600 baud, one line at a time):
#   PHONE:+441234567890
#   <message line 1>
#   <message line 2>
#   ...
#   ###END###
#
# The Arduino buffers the message lines, then on ###END### sends
# them as a single SMS via AT commands to the SIM900.

generate_arduino_sketch()
{

    mkdir -p "$ARDUINO_SKETCH_DIR"

    cat > "$ARDUINO_SKETCH_FILE" <<'CODE_EOF'
/*
 * sim900_report_sender.ino
 *
 * Bridges USB serial (from a PC script) to a SIM900 GPRS/GSM module,
 * sending whatever text it receives as an SMS.
 *
 * Wiring:
 *   SIM900 TX  -> Arduino pin 7 (SoftwareSerial RX)
 *   SIM900 RX  -> Arduino pin 8 (SoftwareSerial TX)
 *   SIM900 GND -> Arduino GND
 *   SIM900 powered from its own supply (NOT the Uno 5V pin -
 *   the module can draw 2A+ current spikes while transmitting).
 *
 *   NOTE: many SIM900 boards run 3.3V logic. If yours does,
 *   put a voltage divider or logic-level shifter on the line
 *   going INTO the Arduino (SIM900 TX -> Arduino pin 7).
 *
 * USB protocol (one line at a time, 9600 baud):
 *   PHONE:+441234567890
 *   <message line 1>
 *   <message line 2>
 *   ...
 *   ###END###
 *
 * On receiving ###END### the buffered message is sent as a
 * single SMS via AT commands to the last PHONE: number given.
 */

#include <SoftwareSerial.h>

SoftwareSerial gsm(7, 8); // RX, TX

String phoneNumber = "";
String messageBuffer = "";
bool haveMessage = false;

void setup()
{
    Serial.begin(9600);
    gsm.begin(9600);

    delay(3000); // let the SIM900 finish booting

    Serial.println("READY");

    gsm.println("AT");
    delay(500);
    flushGsmToSerial();

    gsm.println("AT+CMGF=1"); // text mode SMS
    delay(500);
    flushGsmToSerial();
}

void loop()
{
    if (Serial.available())
    {
        String line = Serial.readStringUntil('\n');
        line.trim();

        if (line.startsWith("PHONE:"))
        {
            phoneNumber = line.substring(6);
            phoneNumber.trim();
            messageBuffer = "";
            haveMessage = false;
            Serial.print("PHONE_SET:");
            Serial.println(phoneNumber);
        }
        else if (line == "###END###")
        {
            if (phoneNumber.length() > 0 && messageBuffer.length() > 0)
            {
                sendSMS(phoneNumber, messageBuffer);
            }
            else
            {
                Serial.println("ERROR:no phone or message set");
            }

            messageBuffer = "";
            haveMessage = false;
        }
        else
        {
            if (haveMessage)
            {
                messageBuffer += "\n";
            }
            messageBuffer += line;
            haveMessage = true;
        }
    }

    // Echo anything the SIM900 says back over USB, useful for debugging
    flushGsmToSerial();
}

void flushGsmToSerial()
{
    while (gsm.available())
    {
        Serial.write(gsm.read());
    }
}

void sendSMS(String number, String message)
{
    Serial.println("SENDING_SMS");

    gsm.print("AT+CMGS=\"");
    gsm.print(number);
    gsm.println("\"");
    delay(500);
    flushGsmToSerial();

    gsm.print(message);
    delay(200);

    gsm.write(26); // Ctrl+Z sends the message
    delay(5000);   // give the module time to transmit

    flushGsmToSerial();

    Serial.println("SMS_DONE");
}
CODE_EOF

    echo
    echo "Arduino sketch written to:"
    echo "  $ARDUINO_SKETCH_FILE"
    echo
    echo "Open it in the Arduino IDE (the folder name must match the"
    echo ".ino filename, which it does) and upload it to your Uno."
    echo
    echo "Wiring reminder:"
    echo "  SIM900 TX  -> Arduino pin 7"
    echo "  SIM900 RX  -> Arduino pin 8"
    echo "  SIM900 GND -> Arduino GND"
    echo "  SIM900 power -> its own supply, not the Uno 5V pin"
    echo

}


is_valid_phone()
{
    [[ "$1" =~ ^\+[0-9]{7,15}$ ]]
}


ensure_sim900_recipients_file()
{

    if [ ! -f "$SIM900_RECIPIENTS_FILE" ]
    then

        cat > "$SIM900_RECIPIENTS_FILE" <<EOF
# One phone number per line, international format (e.g. +441234567890).
# Lines starting with # are ignored.
EOF

        chmod 600 "$SIM900_RECIPIENTS_FILE"

    fi

    # Migrate a number saved by the old single-destination version, if any.
    if [ -f "$SIM900_PHONE_FILE" ]
    then

        local EXISTING_NUM
        EXISTING_NUM="$(cat "$SIM900_PHONE_FILE" 2>/dev/null | xargs)"

        if [ -n "$EXISTING_NUM" ] && ! grep -qFx "$EXISTING_NUM" "$SIM900_RECIPIENTS_FILE" 2>/dev/null
        then
            echo "$EXISTING_NUM" >> "$SIM900_RECIPIENTS_FILE"
        fi

        rm -f "$SIM900_PHONE_FILE"

    fi

}


load_sim900_recipients()
{

    ensure_sim900_recipients_file

    SIM900_RECIPIENTS=()

    while IFS= read -r LINE
    do

        LINE="$(echo "$LINE" | xargs)"

        if [ -z "$LINE" ] || [[ "$LINE" == \#* ]]
        then
            continue
        fi

        SIM900_RECIPIENTS+=("$LINE")

    done < "$SIM900_RECIPIENTS_FILE"

}


list_sim900_recipients()
{

    load_sim900_recipients

    if [ ${#SIM900_RECIPIENTS[@]} -eq 0 ]
    then
        echo "No SMS recipients configured yet."
        return 0
    fi

    echo "Current SMS recipients:"

    local I=1

    for NUM in "${SIM900_RECIPIENTS[@]}"
    do
        echo " $I) $NUM"
        I=$((I + 1))
    done

}


add_sim900_recipient()
{

    ensure_sim900_recipients_file

    echo
    read -p "Enter phone number to add, international format (blank to cancel): " NEW_NUM

    NEW_NUM="$(echo "$NEW_NUM" | xargs)"

    if [ -z "$NEW_NUM" ]
    then
        echo "Cancelled."
        return 0
    fi

    if ! is_valid_phone "$NEW_NUM"
    then
        echo "That doesn't look like a valid international number (expected +<country code><number>). Nothing added."
        return 1
    fi

    load_sim900_recipients

    for EXISTING in "${SIM900_RECIPIENTS[@]}"
    do
        if [ "$EXISTING" == "$NEW_NUM" ]
        then
            echo "$NEW_NUM is already in the list."
            return 0
        fi
    done

    echo "$NEW_NUM" >> "$SIM900_RECIPIENTS_FILE"

    echo "Added $NEW_NUM."

}


remove_sim900_recipient()
{

    load_sim900_recipients

    if [ ${#SIM900_RECIPIENTS[@]} -eq 0 ]
    then
        echo "No SMS recipients to remove."
        return 0
    fi

    list_sim900_recipients

    echo
    read -p "Enter the number to remove (blank to cancel): " NUM

    if [ -z "$NUM" ]
    then
        echo "Cancelled."
        return 0
    fi

    if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [ "$NUM" -lt 1 ] || [ "$NUM" -gt ${#SIM900_RECIPIENTS[@]} ]
    then
        echo "Invalid selection."
        return 1
    fi

    local TARGET="${SIM900_RECIPIENTS[$((NUM - 1))]}"

    grep -vFx "$TARGET" "$SIM900_RECIPIENTS_FILE" > "$SIM900_RECIPIENTS_FILE.tmp" || true
    mv "$SIM900_RECIPIENTS_FILE.tmp" "$SIM900_RECIPIENTS_FILE"

    echo "Removed $TARGET."

}


manage_sim900_recipients_menu()
{

    while true
    do

        echo
        echo "------------------------------------"
        echo " Manage SMS Recipients"
        echo "------------------------------------"
        list_sim900_recipients
        echo
        echo " a) Add recipient"
        echo " r) Remove recipient"
        echo " b) Back"
        echo

        read -p "Choose an option: " CHOICE

        case "$CHOICE" in
            a) add_sim900_recipient ;;
            r) remove_sim900_recipient ;;
            b) break ;;
            *) echo "Invalid option." ;;
        esac

    done

}


detect_serial_port()
{

    local PORTS=()

    while IFS= read -r P
    do
        PORTS+=("$P")
    done < <(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null || true)

    if [ ${#PORTS[@]} -eq 0 ]
    then
        echo ""
        return 1
    fi

    if [ ${#PORTS[@]} -eq 1 ]
    then
        echo "${PORTS[0]}"
        return 0
    fi

    echo "Multiple serial devices found:" >&2

    local I=1
    for P in "${PORTS[@]}"
    do
        echo " $I) $P" >&2
        I=$((I + 1))
    done

    read -p "Which one is the Arduino? " CHOICE >&2

    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#PORTS[@]} ]
    then
        echo "${PORTS[$((CHOICE - 1))]}"
        return 0
    fi

    echo ""
    return 1

}


build_sms_summary()
{

    if [ ! -f "$REPORT" ]
    then
        echo ""
        return 1
    fi

    # SMS has tight length limits, so send a condensed summary
    # rather than the full report.
    awk '
        /^Public IP:/ { getline; ip=$0 }
        /^Internet Provider:/ { getline; org=$0 }
        /^Location:/ { getline; city=$0; getline; region=$0; getline; country=$0 }
        /^Latitude :/ { getline; lat=$0 }
        /^Longitude:/ { getline; lon=$0 }
        END {
            print "IP:" ip " " city ", " region ", " country " (" lat "," lon ")"
        }
    ' "$REPORT"

}


send_via_sim900()
{

    local PORT
    PORT="$(detect_serial_port)"

    if [ -z "$PORT" ]
    then
        echo "No Arduino found on /dev/ttyACM* or /dev/ttyUSB*."
        echo "Check the USB cable and that the sketch has been uploaded."
        return 1
    fi

    load_sim900_recipients

    if [ ${#SIM900_RECIPIENTS[@]} -eq 0 ]
    then
        echo "No SMS recipients configured. Use 'Manage SMS recipients' from this menu first."
        return 1
    fi

    if [ ! -f "$REPORT" ]
    then
        echo "No report found yet — generate one first."
        return 1
    fi

    local SUMMARY
    SUMMARY="$(build_sms_summary)"

    if [ -z "$SUMMARY" ]
    then
        echo "Could not build an SMS summary from the report."
        return 1
    fi

    echo "Using port: $PORT"
    echo "Sending to: ${SIM900_RECIPIENTS[*]}"
    echo "Message: $SUMMARY"
    echo

    stty -F "$PORT" "$SIM900_BAUD" cs8 -cstopb -parenb raw -echo

    exec 3<>"$PORT"

    sleep 2 # allow the Uno to reset after the port opens

    for PHONE in "${SIM900_RECIPIENTS[@]}"
    do

        echo "-> $PHONE"

        printf 'PHONE:%s\n' "$PHONE" >&3
        sleep 1

        printf '%s\n' "$SUMMARY" >&3
        sleep 1

        printf '###END###\n' >&3

        local START_TIME
        START_TIME=$(date +%s)

        while true
        do
            if read -t 1 -u 3 RESPONSE
            then
                echo "  Arduino: $RESPONSE"
                if [[ "$RESPONSE" == "SMS_DONE" ]] || [[ "$RESPONSE" == ERROR:* ]]
                then
                    break
                fi
            fi

            if [ $(( $(date +%s) - START_TIME )) -gt 15 ]
            then
                echo "Timed out waiting for the Arduino to confirm for $PHONE."
                break
            fi
        done

    done

    exec 3<&-
    exec 3>&-

}


sim900_menu()
{

    while true
    do

        echo
        echo "------------------------------------"
        echo " SIM900 GPRS / SMS (via Arduino USB)"
        echo "------------------------------------"

        list_sim900_recipients

        echo
        echo " 1) Generate Arduino sketch"
        echo " 2) Manage SMS recipients"
        echo " 3) Send report summary via SMS now"
        echo " 4) Back to main menu"
        echo

        read -p "Choose an option: " CHOICE

        case "$CHOICE" in
            1) generate_arduino_sketch ;;
            2) manage_sim900_recipients_menu ;;
            3) send_via_sim900 ;;
            4) break ;;
            *) echo "Invalid option." ;;
        esac

    done

}


#############################################
# Full run: report + email
#############################################

run_full_report()
{

    check_os
    check_dependencies
    create_report
    send_email || echo "Continuing despite email issue."

}


#############################################
# Main menu
#############################################

main_menu()
{

    while true
    do

        echo
        echo "===================================="
        echo " Router Location Reporter"
        echo "===================================="
        echo
        echo " 1) Generate report and email it"
        echo " 2) Generate report only"
        echo " 3) Send last report again"
        echo " 4) Manage recipients"
        echo " 5) Gmail / msmtp setup instructions"
        echo " 6) Check dependencies"
        echo " 7) SIM900 GPRS / SMS (via Arduino USB)"
        echo " 8) Exit"
        echo

        read -p "Choose an option: " CHOICE

        case "$CHOICE" in
            1) run_full_report ;;
            2) check_os; create_report ;;
            3) send_email ;;
            4) manage_recipients_menu ;;
            5) show_gmail_setup_info ;;
            6) check_dependencies ;;
            7) sim900_menu ;;
            8) echo "Goodbye."; exit 0 ;;
            *) echo "Invalid option." ;;
        esac

    done

}


#############################################
# Entry point
#############################################

main_menu
