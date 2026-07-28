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
