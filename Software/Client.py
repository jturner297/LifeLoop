import asyncio
import math
import subprocess
import json
import urllib.request
import urllib.error
import re
import time
import sys
from collections import defaultdict
from bleak import BleakScanner, BleakClient

# --- Global Tracking Variables ---
alpha = 0.4
smoothed_lat = None
smoothed_lon = None

last_address_lat = 0.0
last_address_lon = 0.0
last_address_time = 0.0
current_address = "Locating..."  # Holds the persistent address for the dashboard

# Background Wi-Fi tracking variables
current_wifi_lat = None
current_wifi_lon = None

# --- BLE Settings ---
TX_CHARACTERISTIC_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
DEVICE_NAME = "Life Loop"
GOOGLE_API_KEY = "Key"


def apply_ema_smoothing(new_lat, new_lon):
    global smoothed_lat, smoothed_lon
    if smoothed_lat is None or smoothed_lon is None:
        smoothed_lat = new_lat
        smoothed_lon = new_lon
    else:
        smoothed_lat = (alpha * new_lat) + ((1.0 - alpha) * smoothed_lat)
        smoothed_lon = (alpha * new_lon) + ((1.0 - alpha) * smoothed_lon)
    return smoothed_lat, smoothed_lon


def scan_and_average_wifi(interface="wlan0", num_scans=4):
    ap_data = defaultdict(lambda: {"rssi_list": [], "channel": None})

    for pass_num in range(num_scans):
        cmd = ["sudo", "iwlist", interface, "scan"]
        result = subprocess.run(cmd, capture_output=True, text=True)

        current_mac = None
        for line in result.stdout.splitlines():
            line = line.strip()
            if line.startswith("Cell"):
                match = re.search(r"Address:\s*([0-9A-Fa-f:]+)", line)
                if match:
                    current_mac = match.group(1)
            elif current_mac:
                chan_match = re.search(r"Channel:(\d+)", line)
                if chan_match:
                    ap_data[current_mac]["channel"] = int(chan_match.group(1))

                sig_match = re.search(r"Signal level=(-\d+)", line)
                if sig_match:
                    ap_data[current_mac]["rssi_list"].append(int(sig_match.group(1)))

        time.sleep(0.5)

    processed_aps = []
    for mac, data in ap_data.items():
        if data["rssi_list"]:
            avg_rssi = sum(data["rssi_list"]) / len(data["rssi_list"])
            ap_dict = {"macAddress": mac, "signalStrength": int(avg_rssi)}
            if data["channel"] is not None:
                ap_dict["channel"] = data["channel"]
            processed_aps.append(ap_dict)

    processed_aps.sort(key=lambda x: x["signalStrength"], reverse=True)
    return processed_aps[:15]


def get_wifi_geolocation():
    access_points = scan_and_average_wifi(num_scans=4)
    if len(access_points) < 2:
        return None, None

    payload = {
        "considerIp": False,
        "wifiAccessPoints": access_points,
    }

    url = f"https://www.googleapis.com/geolocation/v1/geolocate?key={GOOGLE_API_KEY}"
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            body = response.read().decode("utf-8")
            res = json.loads(body)
            raw_lat = float(res["location"]["lat"])
            raw_lon = float(res["location"]["lng"])
            final_lat, final_lon = apply_ema_smoothing(raw_lat, raw_lon)
            return final_lat, final_lon
    except Exception:
        pass

    return None, None


def get_address_from_coordinates(lat, lon):
    url = (
        f"https://maps.googleapis.com/maps/api/geocode/json?"
        f"latlng={lat},{lon}&key={GOOGLE_API_KEY}"
    )
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read().decode("utf-8"))
            if data["status"] == "OK":
                return data["results"][0]["formatted_address"]
    except Exception:
        pass
    return "Unknown Location"


async def background_wifi_scanner():
    global current_wifi_lat, current_wifi_lon
    while True:
        lat, lon = await asyncio.to_thread(get_wifi_geolocation)
        if lat is not None and lon is not None:
            current_wifi_lat = lat
            current_wifi_lon = lon
        await asyncio.sleep(10)


async def update_address_background(lat, lon):
    """Fetches the address without freezing the UI event loop."""
    global current_address, last_address_lat, last_address_lon, last_address_time

    address = await asyncio.to_thread(get_address_from_coordinates, lat, lon)
    if address != "Unknown Location":
        current_address = address

    last_address_lat = lat
    last_address_lon = lon
    last_address_time = time.time()


def print_dashboard(bpm, lat, lon, location_source, state):
    """Renders a static UI dashboard using ANSI escape sequences."""
    # Hide cursor and move to the top-left of the terminal
    sys.stdout.write("\033[?25l\033[H")

    # Use \033[K to clear the line from the cursor to the end
    sys.stdout.write("\033[K=======================================================\n")
    sys.stdout.write("\033[K              LIFE LOOP WELLNESS MONITOR               \n")
    sys.stdout.write("\033[K=======================================================\n")
    sys.stdout.write(f"\033[K BPM       : {bpm:<6.1f}\n")

    if lat is None or lon is None:
        sys.stdout.write(f"\033[K Location : UNAVAILABLE\n")
        sys.stdout.write(f"\033[K Coords   : N/A\n")
    else:
        sys.stdout.write(f"\033[K Location : {current_address}\n")
        sys.stdout.write(
            f"\033[K Coords   : {lat:.5f}, {lon:.5f} ({location_source})\n"
        )

    sys.stdout.write("\033[K-------------------------------------------------------\n")

    if state == 0:
        sys.stdout.write("\033[K Status: \033[92mNORMAL\033[0m\n")
        sys.stdout.write("\033[K\n")  # Blank line buffer
    elif state == 1:
        sys.stdout.write("\033[K Status: \033[93m[!] FREE FALL DETECTED\033[0m\n")
        sys.stdout.write("\033[K\n")
    elif state == 2:
        sys.stdout.write("\033[K Status: \033[91m[!!] IMPACT DETECTED\033[0m\n")
        sys.stdout.write("\033[K\n")
    elif state == 3:
        sys.stdout.write(
            "\033[K Status: \033[91m\033[1m EMERGENCY PROTOCOL TRIGGERED \033[0m\n"
        )
        sys.stdout.write("\033[K         Dispatching alert to family network...\n")

    sys.stdout.write("\033[K=======================================================\n")

    # Erase any remaining lines below the dashboard
    sys.stdout.write("\033[J")
    sys.stdout.flush()


def notification_handler(sender, data):
    global last_address_time, current_address

    payload = data.decode("utf-8").strip()

    try:
        parts = payload.split("|")
        bpm = float(parts[0].split(":")[1])
        state = int(parts[1].split(":")[1])
        lat = float(parts[2].split(":")[1])
        lon = float(parts[3].split(":")[1])

        location_source = "GPS"

        if lat == 0.0 or lon == 0.0:
            location_source = "Wi-Fi (Smoothed)"
            lat = current_wifi_lat
            lon = current_wifi_lon

        # Address Resolution Task (Throttled)
        current_time = time.time()
        if lat is not None and lon is not None:
            if (current_time - last_address_time) >= 30.0:
                if (
                    abs(lat - last_address_lat) > 0.0001
                    or abs(lon - last_address_lon) > 0.0001
                ):
                    # Fire off the geocoder in the background so it doesn't freeze the dashboard
                    loop = asyncio.get_running_loop()
                    loop.create_task(update_address_background(lat, lon))
                    last_address_time = current_time
                    current_address = "Locating..."  # Provide immediate visual feedback

        # Render the UI
        print_dashboard(bpm, lat, lon, location_source, state)

    except Exception:
        pass


async def run():
    asyncio.create_task(background_wifi_scanner())

    # Initial status output before clearing screen for dashboard
    print(f"Scanning for {DEVICE_NAME}...")
    devices = await BleakScanner.discover()

    target_address = None
    for d in devices:
        if d.name == DEVICE_NAME:
            target_address = d.address
            print(f"Found Life Loop! MAC: {target_address}")
            break

    if not target_address:
        print("Wearable not found. Ensure it is powered on.")
        return

    print("Connecting...")
    async with BleakClient(target_address) as client:
        # Clear the terminal setup text and prepare for the clean dashboard UI
        sys.stdout.write("\033[2J")

        await client.start_notify(TX_CHARACTERISTIC_UUID, notification_handler)

        while True:
            await asyncio.sleep(1.0)


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass
    finally:
        # Crucial: Always restore the cursor visibility when exiting the script
        sys.stdout.write("\033[?25h")
        sys.stdout.flush()
        print("\nExiting Life Loop Monitor.")
